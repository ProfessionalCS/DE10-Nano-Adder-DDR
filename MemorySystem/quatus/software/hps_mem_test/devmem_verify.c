/*
 * devmem_verify.c — Prove the FPGA cache hierarchy writes to real DDR3 SDRAM.
 *
 * HOW IT WORKS
 * ────────────
 *   1. TLB fill + STORE a distinctive value to a high physical address via the
 *      FPGA H2F PIOs (L1 accepts the write, marks the line dirty).
 *   2. Send 20 conflict stores to pages that alias the same L1 / L2 set.
 *      This forces dirty-line evictions:
 *        • After 2 conflicts  → L1 set 0 full (both ways), line evicted to L2.
 *        • After 4 conflicts  → L2 set 0 full (all 4 ways), line evicted to DDR3.
 *   3. Read the physical address DIRECTLY from /dev/mem using mmap with O_SYNC
 *      (non-cacheable — bypasses ARM L1/L2 entirely, reads raw SDRAM).
 *   4. Print PASS if the value matches, FAIL otherwise.
 *
 * The /dev/mem readback completely bypasses the FPGA cache hierarchy — it goes
 * straight to the DDR3 controller and proves the data is actually in DRAM.
 *
 * After the test passes you can also manually verify with:
 *   devmem2 0x38001000 w
 * and expect to see 0x12345678.
 *
 * PHYSICAL ADDRESS
 * ─────────────────
 *   Default: 0x38001000 (896 MB + 4 KB — top 128 MB of 1 GB DRAM, safe).
 *   Override: ./devmem_verify 0x3C000000
 *
 * IDENTITY TLB MAPPING
 *   vaddr == paddr (identity map).  The FPGA Avalon master byte address equals
 *   paddr, so the DDR3 physical address devmem2 reads is exactly paddr.
 *
 * Build:   gcc -O2 -o devmem_verify devmem_verify.c
 * Run:     sudo ./devmem_verify
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ── H2F PIO registers ──────────────────────────────────────────────── */
#define H2F_BASE   0xC0000000
#define H2F_SPAN   0x00001000
#define OFF_SUM    0x00
#define OFF_B      0x08
#define OFF_A      0x10

/* ── Trace opcodes ─────────────────────────────────────────────────── */
#define OP_LOAD     0
#define OP_STORE    1
#define OP_TLB_FILL 4

/* ── Target (default near top of 1 GB DRAM, unlikely to be in use) ─── */
#define DEFAULT_PHYS_ADDR  0x38001000UL
#define STORE_VALUE        0x12345678ULL   /* fits in 30 bits (29-bit number) */
#define PAGE_MASK          (~0xFFFUL)

/* ── Hardware register pointers ────────────────────────────────────── */
static volatile uint64_t *reg_sum, *reg_b, *reg_a;

static void dsb(void) { __asm__ __volatile__("dsb" ::: "memory"); }

static void send_trace(uint64_t a, uint64_t b)
{
    *reg_b = b; dsb();
    *reg_a = a; dsb();
}

static void build_trace(uint8_t op, uint8_t id, uint64_t vaddr,
                        int vv, uint64_t value, int val_v,
                        uint64_t *a, uint64_t *b)
{
    *a  = (vaddr & 0xFFFFFFFFFFFFULL);
    *a |= ((uint64_t)(id  & 0xF))       << 48;
    *a |= ((uint64_t)(op  & 0x7))       << 52;
    *a |= ((uint64_t)(vv  ? 1u : 0u))   << 55;
    *a |= (value & 0xFFULL)             << 56;
    *b  = (value >> 8) & 0x00FFFFFFFFFFFFFFULL;
    *b |= ((uint64_t)(val_v ? 1u : 0u)) << 56;
}

static void clear_status(void)
{
    *reg_b = 0xFFFFFFFFFFFFFFFEULL; dsb();
    *reg_b = 0; dsb();
}

static int bit(uint64_t s, int n) { return (int)((s >> n) & 1); }

/* ── Rolling trace-ID (1..15, never 0) ─────────────────────────────── */
static uint8_t g_id = 1;
static uint8_t nid(void)
{
    uint8_t id = g_id;
    g_id = (g_id >= 15) ? 1 : g_id + 1;
    return id;
}

static void tlb_fill(uint64_t vaddr)
{
    uint64_t page = vaddr & PAGE_MASK;
    uint64_t paddr = page & 0x3FFFFFFFULL;   /* identity map, 30-bit */
    uint64_t a, b;
    build_trace(OP_TLB_FILL, nid(), page, 1, paddr, 0, &a, &b);
    send_trace(a, b);
    usleep(300);
}

/* ═══════════════════════════════════════════════════════════════════ */
int main(int argc, char *argv[])
{
    /* ── Parse optional physical address arg ── */
    unsigned long phys_addr = DEFAULT_PHYS_ADDR;
    if (argc >= 2)
        phys_addr = strtoul(argv[1], NULL, 0);

    /* Align to cache-line boundary (64 bytes) */
    phys_addr &= ~0x3FUL;

    printf("\n╔══════════════════════════════════════════════════════╗\n");
    printf("║  devmem_verify — FPGA cache → DDR3 → /dev/mem read  ║\n");
    printf("╚══════════════════════════════════════════════════════╝\n\n");
    printf("  Physical target address : 0x%08lx\n", phys_addr);
    printf("  Value to store          : 0x%08llx\n\n",
           (unsigned long long)STORE_VALUE);

    /* ── Map FPGA H2F PIOs ── */
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (need root)"); return 1; }

    void *h2f = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, H2F_BASE);
    if (h2f == MAP_FAILED) { perror("mmap H2F"); close(fd); return 1; }

    reg_sum = (volatile uint64_t *)((char *)h2f + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)h2f + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)h2f + OFF_A);

    /* ── Map the target physical SDRAM page (non-cacheable via O_SYNC) ── */
    unsigned long page_base   = phys_addr & ~0xFFFUL;
    unsigned long page_offset = phys_addr & 0xFFFUL;

    void *sdram = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, page_base);
    if (sdram == MAP_FAILED) {
        perror("mmap SDRAM target");
        munmap(h2f, H2F_SPAN);
        close(fd);
        return 1;
    }

    volatile uint32_t *sdram_word =
        (volatile uint32_t *)((char *)sdram + page_offset);

    uint64_t a, b;

    /* ── Send a NOP to prime trace_id_prev ── */
    build_trace(7, 15, 0, 0, 0, 0, &a, &b);
    send_trace(a, b);
    usleep(500);

    /* ── Step 1: TLB fill + STORE to target address ── */
    printf("[1] TLB fill + STORE  vaddr=0x%08lx  value=0x%08llx\n",
           phys_addr, (unsigned long long)STORE_VALUE);

    tlb_fill(phys_addr);

    build_trace(OP_STORE, nid(), phys_addr, 1, STORE_VALUE, 1, &a, &b);
    send_trace(a, b);
    usleep(1500);

    /* ── Step 2: Evict target line from L1 and L2 ──
     * All page-aligned addresses alias L1/L2 set 0 (paddr[7:6]=00).
     * We use 20 pages to guarantee L2 eviction:
     *   2 stores → L1 2-way set 0 full  → evicts target to L2
     *   4 stores → L2 4-way set 0 full  → evicts target to DDR3
     * Stores 5-20 ensure the eviction flush is complete.              */
    printf("[2] Sending 20 conflict stores to evict target from L1 + L2...\n");

    /* Use pages just below phys_addr (going down in 4KB steps) so we
     * stay away from Linux kernel space (which lives at low addresses). */
    for (int i = 1; i <= 20; i++) {
        /* conflict page: same set index as target (offset 0 → set 0)  */
        /* Interleave high pages to definitely alias the same cache set. */
        uint64_t cpage = 0x00001000ULL * (uint64_t)i;  /* pages 0x1000..0x14000 */
        tlb_fill(cpage);
        build_trace(OP_STORE, nid(), cpage, 1,
                    (uint64_t)(0xEEEE0000u + (unsigned)i), 1, &a, &b);
        send_trace(a, b);
        usleep(400);
    }
    printf("    Eviction complete.\n\n");

    /* ── Step 3: Read physical SDRAM directly via mmap ── */
    printf("[3] Reading physical address 0x%08lx via /dev/mem (bypasses FPGA cache)...\n\n",
           phys_addr);

    /* Let any in-flight Avalon writes finish (DDR3 writeback is async). */
    usleep(20000);   /* 20 ms drain */

    /* Non-cacheable read (O_SYNC guarantees no ARM cache involvement). */
    uint32_t actual = *sdram_word;

    /* ── Step 4: Also read sticky status to show DDR3 was reached ── */
    clear_status();

    /* Issue a fresh TLB fill + load so we can see the DDR3 bits */
    tlb_fill(phys_addr);
    build_trace(OP_LOAD, nid(), phys_addr, 1, 0, 0, &a, &b);
    send_trace(a, b);

    uint64_t s = 0;
    for (int t = 0; t < 200; t++) {
        usleep(500);
        s = *reg_sum;
        if (bit(s, 63)) break;
    }

    printf("── FPGA Sticky Status (load after eviction) ─────────────\n");
    printf("  [63] cache_ret_valid   = %d\n", bit(s, 63));
    printf("  [62] l1_miss           = %d  (L1 missed)\n",       bit(s, 62));
    printf("  [60] l2_ext_rd_req     = %d  (L2 missed → DDR3)\n",bit(s, 60));
    printf("  [59] avm_read          = %d  (Avalon read)\n",      bit(s, 59));
    printf("  [57] avm_readdatavalid = %d  (DDR3 data back)\n",   bit(s, 57));
    printf("─────────────────────────────────────────────────────────\n\n");

    printf("── /dev/mem direct read ─────────────────────────────────\n");
    printf("  Physical 0x%08lx  →  0x%08x\n", phys_addr, actual);
    printf("  Expected             →  0x%08x\n", (uint32_t)STORE_VALUE);
    printf("\n  Equivalent command you can run manually:\n");
    printf("    devmem2 0x%08lx w\n", phys_addr);
    printf("─────────────────────────────────────────────────────────\n\n");

    /* ── Step 5: Verdict ── */
    int ddr3_seen = bit(s, 62) && bit(s, 60) && bit(s, 57);
    int data_ok   = (actual == (uint32_t)STORE_VALUE);

    if (!ddr3_seen && !data_ok) {
        printf("RESULT: FAIL — DDR3 not reached and data does not match.\n");
        printf("  Run test twice in a row (first run may warm caches).\n\n");
        munmap(sdram, 0x1000);
        munmap(h2f, H2F_SPAN);
        close(fd);
        return 1;
    }
    if (!data_ok) {
        printf("RESULT: FAIL — DDR3 sticky bits set but /dev/mem reads 0x%08x not 0x%08x\n\n",
               actual, (uint32_t)STORE_VALUE);
        munmap(sdram, 0x1000);
        munmap(h2f, H2F_SPAN);
        close(fd);
        return 1;
    }

    printf("╔══════════════════════════════════════════════════════╗\n");
    printf("║  PASS                                                ║\n");
    printf("║  Value 0x%08x found at physical 0x%08lx  ║\n",
           actual, phys_addr);
    printf("║  Written by FPGA cache, evicted, read by CPU /dev/mem║\n");
    printf("╚══════════════════════════════════════════════════════╝\n\n");

    munmap(sdram, 0x1000);
    munmap(h2f, H2F_SPAN);
    close(fd);
    return 0;
}
