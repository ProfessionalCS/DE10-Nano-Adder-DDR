/*
 * adder_test.c — Verify the simple dual-adder FPGA design
 *
 * ═══════════════════════════════════════════════════════════════
 *  ROOT CAUSE OF THE ORIGINAL HANG:
 *
 *  The old code used LW_BASE = 0xFF200000 (Lightweight H2F bridge).
 *  But the Qsys design has LWH2F_Enable = false — that bridge is
 *  DISABLED in the bitstream.  Any /dev/mem access to that window
 *  hangs the AXI bus permanently and kills the SSH session.
 *
 *  FIX: use the full H2F bridge at 0xC0000000.
 * ═══════════════════════════════════════════════════════════════
 *
 *  PIO address map  (full H2F bridge @ 0xC0000000):
 *
 *    0xC0000000  pio128[31:0]      WRITE → 128-bit PIO word 0
 *    0xC0000004  pio128[63:32]     WRITE → 128-bit PIO word 1
 *    0xC0000008  pio128[95:64]     WRITE → 128-bit PIO word 2
 *    0xC000000C  pio128[127:96]    WRITE → 128-bit PIO word 3
 *    0xC0000010  adder_sum[31:0]   READ  → sum_a = adder_a[31:0] + adder_b[31:0]
 *    0xC0000014  adder_sum[63:32]  READ  → debug_word (see below)
 *    0xC0000018  adder_b[31:0]     WRITE → operand 2
 *    0xC000001C  adder_b[63:32]    WRITE → (unused, writes zero lower half)
 *    0xC0000020  adder_a[31:0]     WRITE → operand 1 / DEADBEEF trigger
 *    0xC0000024  adder_a[63:32]    WRITE → (unused, writes zero lower half)
 *
 *  debug_word at 0xC0000014:
 *    [31:24] = 0xDB  magic marker — if missing, bridge not working
 *    [23]    = heartbeat — toggling every ~1 s (FPGA clock alive)
 *    [22]    = hps_reset_n — 1 = HPS running
 *    [21]    = pio_dirty — FPGA saw a new write
 *    [20]    = ddr3_written — DDR3 has been written at least once
 *    [19:18] = seq state (0=idle, 1=writing_A, 2=writing_B)
 *
 *  PROTOCOL (why cross-PIO):
 *    pio64_out has no byteenable port.  A 32-bit HPS write to the
 *    LOW 32 bits of a 64-bit PIO zeroes the HIGH 32 bits and vice-
 *    versa.  So we CANNOT add adder_a[31:0] + adder_a[63:32] via
 *    two separate 32-bit writes — the second write clears the first.
 *    Instead: operand 1 → adder_a LOW, operand 2 → adder_b LOW.
 *    These are different PIO instances; writes do not interfere.
 *
 *  DDR3 write-through (FPGA writes 64-byte cache line per adder):
 *    0x3FFF003C  sum_a  (32-bit word at offset 0x3C in 64-byte line)
 *    0x3FFF007C  sum_b  (32-bit word at offset 0x7C in 64-byte line)
 *
 *  DEADBEEF LED trigger:
 *    When adder_a[31:0] == 0xDEADBEEF → LED[3:0] latches adder_b[3:0]
 *    LED[7] = heartbeat (always blinking)
 *    LED[6] = pio_dirty,  LED[5] = seq active,  LED[4] = HPS reset
 *
 * Build:  gcc -O2 -o adder_test adder_test.c
 * Run:    ./enable_bridges && ./adder_test
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>

/* ── Full H2F bridge (was WRONG: 0xFF200000 = LW bridge, DISABLED) ── */
#define H2F_BASE   0xC0000000u
#define H2F_SPAN   0x28u

/* PIO offsets within the H2F window                                    */
/* pio128_out sits at 0x00-0x0F (128-bit write-only, byteenable-aware)  */
#define P128_W0   0x00u   /* pio128[31:0]     (WRITE) */
#define P128_W1   0x04u   /* pio128[63:32]    (WRITE) */
#define P128_W2   0x08u   /* pio128[95:64]    (WRITE) */
#define P128_W3   0x0Cu   /* pio128[127:96]   (WRITE) */
/* pio64_in at 0x10-0x17 (64-bit read-only)                             */
#define SUM_LO    0x10u   /* adder_sum[31:0]  = sum_a     (READ)  */
#define DBG_HI    0x14u   /* adder_sum[63:32] = debug_word (READ)  */
/* pio64_out_1 at 0x18-0x1F (64-bit write-only, adder_b)               */
#define B_LO      0x18u   /* adder_b[31:0]    = operand 2 (WRITE) */
#define B_HI      0x1Cu   /* adder_b[63:32]   (avoid — clears B_LO) */
/* pio64_out_0 at 0x20-0x27 (64-bit write-only, adder_a)               */
#define A_LO      0x20u   /* adder_a[31:0]    = operand 1 (WRITE) */
#define A_HI      0x24u   /* adder_a[63:32]   (avoid — clears A_LO) */

/* DDR3 physical addresses where FPGA writes the cache lines */
#define DDR3_SUM_A  0x3FFF003Cu
#define DDR3_SUM_B  0x3FFF007Cu

/* debug_word magic marker expected in bits [31:24] */
#define DBG_MAGIC   0xDBu

static int fd;
static volatile uint32_t *pio;

static void wr(unsigned off, uint32_t v)
{
    printf("  [DBG] write 0x%08X → PIO[0x%02X]  (phys 0x%08X)\n",
           v, off, H2F_BASE + off);
    pio[off/4] = v;
}

static uint32_t rd(unsigned off)
{
    uint32_t v = pio[off/4];
    printf("  [DBG] read  PIO[0x%02X] (phys 0x%08X) → 0x%08X\n",
           off, H2F_BASE + off, v);
    return v;
}

/* Map a single 32-bit word from a physical DDR3 address */
static uint32_t ddr3_read(uint32_t pa)
{
    uint32_t page = pa & ~0xFFFu;
    volatile uint32_t *p = mmap(NULL, 0x1000, PROT_READ,
                                 MAP_SHARED, fd, page);
    if (p == MAP_FAILED) { perror("mmap ddr3"); exit(1); }
    uint32_t v = p[(pa & 0xFFFu) / 4];
    printf("  [DBG] DDR3 read phys=0x%08X → 0x%08X\n", pa, v);
    munmap((void *)p, 0x1000);
    return v;
}

static int check(const char *label, uint32_t got, uint32_t want)
{
    int ok = (got == want);
    printf("  %-38s 0x%08X  %s", label, got, ok ? "OK" : "FAIL");
    if (!ok) printf("  (expected 0x%08X)", want);
    printf("\n");
    return ok;
}

/* ── Dump debug_word for diagnostic output ── */
static void dump_debug(uint32_t dbg)
{
    printf("  [DBG] debug_word = 0x%08X\n", dbg);
    printf("        magic      = 0x%02X  %s\n",
           (dbg >> 24) & 0xFF,
           ((dbg >> 24) & 0xFF) == DBG_MAGIC ? "(OK)" : "(WRONG! bridge may not be responding)");
    printf("        heartbeat  = %u  (FPGA clock alive)\n", (dbg >> 23) & 1);
    printf("        hps_reset  = %u  (1=HPS running)\n",   (dbg >> 22) & 1);
    printf("        pio_dirty  = %u  (1=FPGA saw write)\n",(dbg >> 21) & 1);
    printf("        ddr3_done  = %u  (1=DDR3 written)\n",  (dbg >> 20) & 1);
    printf("        seq_state  = %u  (0=idle)\n",          (dbg >> 18) & 3);
}

int main(void)
{
    printf("\n");
    printf("╔══════════════════════════════════════════════════╗\n");
    printf("║  DE10-Nano Adder Test  (full H2F bridge edition) ║\n");
    printf("╚══════════════════════════════════════════════════╝\n");
    printf("  Bridge base: 0x%08X  (was wrong: 0xFF200000)\n\n", H2F_BASE);

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    pio = mmap(NULL, H2F_SPAN, PROT_READ|PROT_WRITE,
               MAP_SHARED, fd, H2F_BASE);
    if (pio == MAP_FAILED) { perror("mmap H2F bridge"); return 1; }

    int pass = 1;

    /* ── Sanity: read debug word before any write ────────────────── */
    printf("Pre-test debug word (should show 0xDB magic):\n");
    dump_debug(rd(DBG_HI));
    printf("\n");

    /* ── Test 1: Adder  (operand_1=0x1000, operand_2=0x0234 → 0x1234) */
    printf("Test 1: adder_a[31:0]=0x1000  +  adder_b[31:0]=0x0234  =  0x1234\n");
    printf("  (write operand 1 to adder_a, operand 2 to adder_b — separate PIOs)\n");
    wr(A_LO, 0x00001000u);   /* adder_a low 32 = 0x1000 */
    wr(B_LO, 0x00000234u);   /* adder_b low 32 = 0x0234 */
    usleep(1000);
    pass &= check("sum_a @ 0xC0000010", rd(SUM_LO), 0x00001234u);

    dump_debug(rd(DBG_HI));
    printf("\n");

    /* ── Test 2: different values ────────────────────────────────── */
    printf("Test 2: adder_a=0x00FF  +  adder_b=0x0001  =  0x0100\n");
    wr(A_LO, 0x000000FFu);
    wr(B_LO, 0x00000001u);
    usleep(1000);
    pass &= check("sum_a @ 0xC0000010", rd(SUM_LO), 0x00000100u);
    printf("\n");

    /* ── Test 3: DDR3 readback ───────────────────────────────────── */
    printf("Test 3: DDR3 readback (FPGA writes sum_a to DDR3 at 0x3FFF003C)\n");
    printf("  Waiting 15 ms for Avalon writes to complete...\n");
    usleep(15000);
    pass &= check("DDR3 sum_a @ 0x3FFF003C", ddr3_read(DDR3_SUM_A), 0x00000100u);
    dump_debug(rd(DBG_HI));  /* ddr3_written bit should now be 1 */
    printf("\n");

    /* ── Test 4: DEADBEEF → LED latch ───────────────────────────── */
    printf("Test 4: DEADBEEF trigger\n");
    printf("  Write B_LO=0x05 (LED pattern), then A_LO=0xDEADBEEF (trigger)\n");
    printf("  Expected: LED[3:0] latch = 0x5 (binary 0101)\n");
    wr(B_LO, 0x00000005u);   /* set adder_b low bits = 0x5 → goes to LED[3:0] */
    usleep(1000);
    wr(A_LO, 0xDEADBEEFu);   /* trigger: adder_a[31:0]==DEADBEEF → latch fires */
    usleep(1000);
    pass &= check("adder_a reads back DEADBEEF", rd(SUM_LO),
                  0xDEADBEEFu + 0x00000005u);  /* sum_a = 0xDEADBEEF + 0x5 */
    printf("  *** Check LEDs on board: LED[7] should blink, LED[3:0] = 0101 ***\n");
    printf("\n");

    /* ── Final debug dump ──────────────────────────────────────────── */
    printf("Final debug word:\n");
    dump_debug(rd(DBG_HI));
    printf("\n");

    munmap((void *)pio, H2F_SPAN);
    close(fd);

    printf("─────────────────────────────────────────────────────\n");
    printf("  %s\n\n", pass ? "ALL TESTS PASSED ✓" : "SOME TESTS FAILED ✗");
    return pass ? 0 : 1;
}
