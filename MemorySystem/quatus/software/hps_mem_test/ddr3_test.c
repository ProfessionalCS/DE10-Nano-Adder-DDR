/*
 * ddr3_test.c — Focused proof that the FPGA memory hierarchy reaches DDR3.
 *
 * Strategy
 * --------
 *   L1  = 2-way, 4-set  →  8 cache lines (512 B total)
 *   L2  = 4-way, 4-set  → 16 cache lines (1 KB total, compiled for FPGA)
 *
 *   All page-aligned addresses (vaddr & ~0xFFF == vaddr) always index into
 *   L1/L2 set 0 because block_addr = paddr>>6, and (N*0x1000)>>6 = N*0x40,
 *   and 0x40 % 4 == 0.  So just using different page numbers is enough to
 *   force conflicts and evictions.
 *
 *   Steps:
 *     1. TLB-fill + STORE 0x12345678 to address 0x10000.
 *     2. TLB-fill + STORE dummy values to 20 other pages (0x11000–0x24000).
 *        After 2 conflict stores → L1 set 0 full (both ways evicted).
 *        After 4 conflict stores → L2 set 0 full (all 4 ways evicted).
 *        Stores 5–20 → each eviction writes 0x10000's line out to DDR3.
 *     3. Re-fill TLB for 0x10000, clear sticky status, issue LOAD 0x10000.
 *        L1 miss  → sticky bit 62 set.
 *        L2 miss  → sticky bit 60 set (l2_ext_rd_req).
 *        Avalon read → bits 59, 58, 57 set.
 *     4. Check sticky bits + returned value.  Print PASS or FAIL.
 *
 * Build on board:   gcc -O2 -o ddr3_test ddr3_test.c
 * Run as root:      sudo ./ddr3_test
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ── HPS → FPGA bridge ─────────────────────────────────────────────── */
#define H2F_BASE   0xC0000000
#define H2F_SPAN   0x00001000
#define OFF_SUM    0x00   /* pio64_in_0  : FPGA → HPS (status) */
#define OFF_B      0x08   /* pio64_out_1 : HPS → FPGA          */
#define OFF_A      0x10   /* pio64_out_0 : HPS → FPGA          */

/* ── Trace opcodes ─────────────────────────────────────────────────── */
#define OP_LOAD     0
#define OP_STORE    1
#define OP_TLB_FILL 4

/* ── Sticky status bit positions (DE10_NANO_SoC_GHRD.v) ─────────────
 *   63 : ever cache_ret_valid   (L1 returned data to LSQ)
 *   62 : ever obs_l2_req_valid  (L1 miss → sent request to L2)
 *   61 : ever obs_wb_valid      (dirty writeback from L1)
 *   60 : ever l2_ext_rd_req     (L2 miss → DDR3 fetch issued)
 *   59 : ever avm_read          (Avalon master asserted read)
 *   58 : ever avm beat accepted (!waitrequest while avm_read)
 *   57 : ever avm_readdatavalid (DDR3 actually returned data)
 * 56:30 : wb_addr[26:0]          latched at last writeback
 * 29: 0 : cache_ret_data[29:0]   latched at last cache return
 * ─────────────────────────────────────────────────────────────────── */
#define BIT_CACHE_RET  63
#define BIT_L1_MISS    62
#define BIT_L2_DDR3    60   /* L2 ext read request → DDR3 fetch */
#define BIT_AVM_RD     59
#define BIT_AVM_ACC    58
#define BIT_AVM_DV     57   /* readdatavalid: DDR3 data came back */

/* ── Hardware register pointers ────────────────────────────────────── */
static volatile uint64_t *reg_sum, *reg_b, *reg_a;

static void dsb(void)
{
    __asm__ __volatile__("dsb" ::: "memory");
}

static void send_trace(uint64_t a, uint64_t b)
{
    /* Write adder_b FIRST, then adder_a.  The LSQ triggers on id change
     * inside adder_a, so adder_b must already be valid. */
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
    /* Writing adder_b[63:57] = 1111111 triggers the clear logic. */
    *reg_b = 0xFFFFFFFFFFFFFFFEULL; dsb();
    *reg_b = 0; dsb();
}

static uint64_t read_status(void)
{
    return *reg_sum;
}

/* ── Rolling trace-ID (1..15, never 0) ─────────────────────────────── */
static uint8_t g_id = 1;

static uint8_t nid(void)
{
    uint8_t id = g_id;
    g_id = (g_id >= 15) ? 1 : g_id + 1;
    return id;
}

/* ── Identity-mapped TLB fill for one page ─────────────────────────── */
static void tlb_fill(uint64_t page)
{
    uint64_t a, b;
    /* paddr = vaddr (identity map); only page bits matter */
    build_trace(OP_TLB_FILL, nid(), page, 1, page & 0x3FFFFFFFULL, 0, &a, &b);
    send_trace(a, b);
    usleep(300);
}

static int bit(uint64_t s, int n) { return (int)((s >> n) & 1); }

/* ═══════════════════════════════════════════════════════════════════ */
int main(void)
{
    /* ── Open /dev/mem ── */
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem — run as root"); return 1; }

    void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    reg_sum = (volatile uint64_t *)((char *)base + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)base + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)base + OFF_A);

    printf("\n╔══════════════════════════════════════════════╗\n");
    printf("║         DDR3 Access Test                     ║\n");
    printf("╚══════════════════════════════════════════════╝\n\n");

    uint64_t a, b;

    /* Send a harmless NOP so trace_id_prev is defined. */
    build_trace(7, 15, 0, 0, 0, 0, &a, &b);
    send_trace(a, b);
    usleep(500);

    /* ── Target address and value ── */
    const uint64_t TARGET = 0x10000ULL;         /* page 0x10, offset 0 */
    const uint64_t VALUE  = 0x12345678ULL;      /* fits in 30 bits */
    const uint32_t EXP30  = (uint32_t)(VALUE & 0x3FFFFFFFu);

    /* ── Step 1: Store known value to target ── */
    printf("[1] TLB-fill + STORE  vaddr=0x%06llx  value=0x%08x\n",
           (unsigned long long)TARGET, (unsigned int)VALUE);

    tlb_fill(TARGET & ~0xFFFULL);

    build_trace(OP_STORE, nid(), TARGET, 1, VALUE, 1, &a, &b);
    send_trace(a, b);
    usleep(1500);

    /* ── Step 2: Evict by storing to 20 pages that alias L1/L2 set 0 ── */
    printf("[2] Evicting with 20 conflict stores (pages 0x11000–0x24000)...\n");

    for (int i = 1; i <= 20; i++) {
        uint64_t page = 0x11000ULL + (uint64_t)(i - 1) * 0x1000ULL;
        tlb_fill(page);
        build_trace(OP_STORE, nid(), page, 1, (uint64_t)(0xEEEE0000u + i), 1, &a, &b);
        send_trace(a, b);
        usleep(400);
    }

    printf("    Done. 0x%06llx should now be in DDR3 (evicted from L1 + L2).\n\n",
           (unsigned long long)TARGET);

    /* ── Step 3: Re-fill TLB, clear sticky status, issue LOAD ── */
    printf("[3] LOAD  vaddr=0x%06llx  (expect L1 miss → L2 miss → DDR3)\n\n",
           (unsigned long long)TARGET);

    tlb_fill(TARGET & ~0xFFFULL);   /* hardware TLB (16 entries) may have evicted it */
    usleep(200);

    clear_status();

    build_trace(OP_LOAD, nid(), TARGET, 1, 0, 0, &a, &b);
    send_trace(a, b);

    /* Poll for cache_ret_valid up to 100 ms */
    uint64_t s = 0;
    for (int t = 0; t < 200; t++) {
        usleep(500);
        s = read_status();
        if (bit(s, BIT_CACHE_RET)) break;
    }

    /* ── Step 4: Print decoded status ── */
    uint32_t ret = (uint32_t)(s & 0x3FFFFFFFu);

    printf("── Status Register ──────────────────────────────\n");
    printf("  [63] cache_ret_valid  = %d  (L1 returned data to LSQ)\n",  bit(s, 63));
    printf("  [62] l1_miss          = %d  (L1 cache miss → went to L2)\n", bit(s, 62));
    printf("  [60] l2_ext_rd_req    = %d  (L2 miss → DDR3 fetch issued)\n", bit(s, 60));
    printf("  [59] avm_read         = %d  (Avalon master sent DDR3 read)\n", bit(s, 59));
    printf("  [58] avm_accepted     = %d  (DDR3 bridge de-asserted waitreq)\n", bit(s, 58));
    printf("  [57] avm_readdatavalid= %d  (DDR3 returned data)\n",          bit(s, 57));
    printf("  returned  [29:0]      = 0x%08x\n", ret);
    printf("  expected  [29:0]      = 0x%08x\n", EXP30);
    printf("─────────────────────────────────────────────────\n\n");

    /* ── Step 5: Verdict ── */
    int got_ret   = bit(s, BIT_CACHE_RET);
    int l1_miss   = bit(s, BIT_L1_MISS);
    int l2_ddr3   = bit(s, BIT_L2_DDR3);
    int avm_dv    = bit(s, BIT_AVM_DV);
    int ddr3_seen = (l1_miss && l2_ddr3 && avm_dv);
    int data_ok   = (got_ret && (ret == EXP30));

    if (!got_ret) {
        printf("RESULT: FAIL  — no cache_ret_valid (pipeline did not respond)\n\n");
        return 1;
    }
    if (!ddr3_seen) {
        printf("RESULT: FAIL  — DDR3 not reached "
               "(l1_miss=%d l2_ddr3=%d avm_dv=%d)\n", l1_miss, l2_ddr3, avm_dv);
        printf("         Data served from cache (not evicted yet).\n");
        printf("         Run the test a second time — eviction is guaranteed then.\n\n");
        return 1;
    }
    if (!data_ok) {
        printf("RESULT: FAIL  — DDR3 accessed but data wrong "
               "(got=0x%08x exp=0x%08x)\n\n", ret, EXP30);
        return 1;
    }

    printf("╔══════════════════════════════════════════════╗\n");
    printf("║  PASS — DDR3 accessed and data is correct!  ║\n");
    printf("╚══════════════════════════════════════════════╝\n\n");

    munmap(base, H2F_SPAN);
    close(fd);
    return 0;
}
