/*
 * stress_test.c — Comprehensive stress test for FPGA memory hierarchy.
 *
 * Tests the full L1 → L2 → DDR3 path with multiple patterns:
 *   1. Multiple data patterns (walking bits, all-1s, sequential)
 *   2. Back-to-back DDR3 reads (multiple unique addresses)
 *   3. RAW (Read-After-Write) chains
 *   4. TLB pressure (>16 pages, forces DTLB eviction + re-fill)
 *   5. Cross-set L2 misses (different L2 sets)
 *   6. Repeated iteration stress
 *
 * Build:  gcc -O2 -o stress_test stress_test.c
 * Run:    sudo ./stress_test
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
#define OFF_SUM    0x00
#define OFF_B      0x08
#define OFF_A      0x10

#define OP_LOAD     0
#define OP_STORE    1
#define OP_TLB_FILL 4

#define BIT_CACHE_RET  63
#define BIT_L1_MISS    62
#define BIT_L2_DDR3    60
#define BIT_AVM_RD     59
#define BIT_AVM_ACC    58
#define BIT_AVM_DV     57

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
    *reg_a = 0; dsb();
    *reg_b = 0xFFFFFFFFFFFFFFFEULL; dsb();
    *reg_b = 0; dsb();
}

static uint64_t read_status(void) { return *reg_sum; }

static uint8_t g_id = 1;
static uint8_t nid(void)
{
    uint8_t id = g_id;
    g_id = (g_id >= 15) ? 1 : g_id + 1;
    return id;
}

static int bit(uint64_t s, int n) { return (int)((s >> n) & 1); }

/* Always send TLB fill (never cache - HW TLB has only 16 entries) */
static void tlb_fill(uint64_t page)
{
    uint64_t a, b;
    build_trace(OP_TLB_FILL, nid(), page, 1, page & 0x3FFFFFFFULL, 0, &a, &b);
    send_trace(a, b);
    usleep(300);
}

/* Store a value, wait for completion */
static void do_store(uint64_t vaddr, uint64_t value)
{
    uint64_t a, b;
    tlb_fill(vaddr & ~0xFFFULL);
    clear_status();
    build_trace(OP_STORE, nid(), vaddr, 1, value, 1, &a, &b);
    send_trace(a, b);
    usleep(1500);
}

/* Load and return the 30-bit value; sets *status to full status word */
static uint32_t do_load(uint64_t vaddr, uint64_t *status)
{
    uint64_t a, b;
    tlb_fill(vaddr & ~0xFFFULL);
    clear_status();
    build_trace(OP_LOAD, nid(), vaddr, 1, 0, 0, &a, &b);
    send_trace(a, b);

    uint64_t s = 0;
    for (int t = 0; t < 200; t++) {
        usleep(500);
        s = read_status();
        if (bit(s, BIT_CACHE_RET)) break;
    }
    if (status) *status = s;
    return (uint32_t)(s & 0x3FFFFFFFu);
}

/* ── Test counters ─────────────────────────────────────────────────── */
static int total_pass = 0, total_fail = 0, total_timeout = 0;

static int check(const char *name, uint64_t vaddr, uint64_t expected)
{
    uint64_t s;
    uint32_t ret = do_load(vaddr, &s);
    uint32_t exp30 = (uint32_t)(expected & 0x3FFFFFFFu);
    int got_ret = bit(s, BIT_CACHE_RET);

    if (!got_ret) {
        printf("  [TIMEOUT] %s  vaddr=0x%06llx\n", name, (unsigned long long)vaddr);
        total_timeout++;
        return 0;
    }
    if (ret != exp30) {
        printf("  [FAIL]    %s  vaddr=0x%06llx  got=0x%08x  exp=0x%08x\n",
               name, (unsigned long long)vaddr, ret, exp30);
        total_fail++;
        return 0;
    }
    total_pass++;
    return 1;
}

/* Force eviction of a specific page by filling L1+L2 set with conflicts */
static void evict_via_conflicts(uint64_t target_page, int n_evict)
{
    /* Use pages far away from target to avoid TLB conflicts */
    for (int i = 1; i <= n_evict; i++) {
        uint64_t page = 0x80000ULL + (uint64_t)i * 0x1000ULL;
        do_store(page, 0xEE000000ULL + i);
    }
}

/* ═══════════════════════════════════════════════════════════════════ */

static void test1_data_patterns(void)
{
    printf("\n━━━ Test 1: Data Patterns ━━━\n");
    /* Store known patterns to different pages, evict, read back from DDR3 */
    struct { uint64_t addr; uint64_t val; const char *name; } cases[] = {
        { 0x30000, 0x00000000ULL, "all-zeros"     },
        { 0x31000, 0x3FFFFFFFULL, "all-ones(30b)" },
        { 0x32000, 0x2AAAAAAAULL, "alternating-A" },
        { 0x33000, 0x15555555ULL, "alternating-5" },
        { 0x34000, 0x00000001ULL, "walking-1-b0"  },
        { 0x35000, 0x20000000ULL, "walking-1-b29" },
        { 0x36000, 0x12345678ULL, "sequential"    },
        { 0x37000, 0x0FEDCBA9ULL, "reverse-seq"   },
    };
    int n = sizeof(cases) / sizeof(cases[0]);

    for (int i = 0; i < n; i++)
        do_store(cases[i].addr, cases[i].val);

    /* Evict everything by writing 20 conflict pages */
    evict_via_conflicts(0x30000, 20);

    int sub_pass = 0;
    for (int i = 0; i < n; i++)
        sub_pass += check(cases[i].name, cases[i].addr, cases[i].val);

    printf("  Data patterns: %d/%d passed\n", sub_pass, n);
}

static void test2_back_to_back_ddr3(void)
{
    printf("\n━━━ Test 2: Back-to-Back DDR3 Reads ━━━\n");
    /* Store to 8 different pages, evict all, then read all back-to-back */
    int n = 8;
    for (int i = 0; i < n; i++) {
        uint64_t addr = 0x40000ULL + (uint64_t)i * 0x1000ULL;
        do_store(addr, 0xBB000000ULL + i);
    }
    evict_via_conflicts(0x40000, 20);

    int sub_pass = 0;
    for (int i = 0; i < n; i++) {
        uint64_t addr = 0x40000ULL + (uint64_t)i * 0x1000ULL;
        uint64_t exp  = 0xBB000000ULL + i;
        sub_pass += check("b2b-ddr3", addr, exp);
    }
    printf("  Back-to-back DDR3: %d/%d passed\n", sub_pass, n);
}

static void test3_raw_chains(void)
{
    printf("\n━━━ Test 3: Read-After-Write (immediate) ━━━\n");
    /* Store then immediately read back (should be L1 hit) */
    int sub_pass = 0;
    for (int i = 0; i < 8; i++) {
        uint64_t addr = 0x50000ULL + (uint64_t)i * 0x1000ULL;
        uint64_t val  = 0xAA000000ULL + i * 0x111;
        do_store(addr, val);
        sub_pass += check("raw-immed", addr, val);
    }
    printf("  RAW immediate: %d/%d passed\n", sub_pass, 8);
}

static void test4_tlb_pressure(void)
{
    printf("\n━━━ Test 4: TLB Pressure (>16 pages) ━━━\n");
    /* Access 24 distinct pages - forces TLB eviction and re-fill */
    int n = 24;
    for (int i = 0; i < n; i++) {
        uint64_t addr = 0x60000ULL + (uint64_t)i * 0x1000ULL;
        do_store(addr, 0xCC000000ULL + i);
    }
    evict_via_conflicts(0x60000, 20);

    /* Read all back - TLB fills happen inside do_load automatically */
    int sub_pass = 0;
    for (int i = 0; i < n; i++) {
        uint64_t addr = 0x60000ULL + (uint64_t)i * 0x1000ULL;
        sub_pass += check("tlb-press", addr, 0xCC000000ULL + i);
    }
    printf("  TLB pressure (%d pages): %d/%d passed\n", n, sub_pass, n);
}

static void test5_cross_set_l2(void)
{
    printf("\n━━━ Test 5: Cross-Set L2 Misses ━━━\n");
    /* L2 set index = block_addr[1:0] = paddr[7:6]. Use offsets 0x00, 0x40,
     * 0x80, 0xC0 to hit all 4 L2 sets. */
    struct { uint64_t addr; uint64_t val; } cases[16];
    int n = 0;
    for (int set = 0; set < 4; set++) {
        for (int pg = 0; pg < 4; pg++) {
            uint64_t addr = 0x70000ULL + (uint64_t)(set*4+pg) * 0x1000ULL
                          + (uint64_t)set * 0x40ULL;
            cases[n].addr = addr;
            cases[n].val  = 0xDD000000ULL + set * 0x100 + pg;
            n++;
        }
    }

    for (int i = 0; i < n; i++)
        do_store(cases[i].addr, cases[i].val);

    evict_via_conflicts(0x70000, 20);

    int sub_pass = 0;
    for (int i = 0; i < n; i++)
        sub_pass += check("xset-l2", cases[i].addr, cases[i].val);
    printf("  Cross-set L2: %d/%d passed\n", sub_pass, n);
}

static void test6_overwrite_and_verify(void)
{
    printf("\n━━━ Test 6: Overwrite + Re-Read ━━━\n");
    uint64_t addr = 0xA0000ULL;

    /* Store initial value, evict to DDR3 */
    do_store(addr, 0x11111111ULL);
    evict_via_conflicts(addr, 20);
    int ok = check("initial", addr, 0x11111111ULL);

    /* Overwrite with new value, evict again */
    do_store(addr, 0x22222222ULL);
    evict_via_conflicts(addr, 20);
    ok += check("overwrite", addr, 0x22222222ULL);

    printf("  Overwrite: %d/2 passed\n", ok);
}

static void test7_iteration_stress(void)
{
    printf("\n━━━ Test 7: Iteration Stress (5 rounds) ━━━\n");
    int sub_pass = 0, sub_total = 0;

    for (int round = 0; round < 5; round++) {
        uint64_t base = 0xB0000ULL + (uint64_t)round * 0x8000ULL;
        int n = 4;

        for (int i = 0; i < n; i++) {
            uint64_t addr = base + (uint64_t)i * 0x1000ULL;
            do_store(addr, 0xFF000000ULL + round * 0x100 + i);
        }
        evict_via_conflicts(base, 20);

        for (int i = 0; i < n; i++) {
            uint64_t addr = base + (uint64_t)i * 0x1000ULL;
            sub_pass += check("iter-stress", addr, 0xFF000000ULL + round * 0x100 + i);
            sub_total++;
        }
    }
    printf("  Iteration stress: %d/%d passed\n", sub_pass, sub_total);
}

/* ═══════════════════════════════════════════════════════════════════ */
int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    reg_sum = (volatile uint64_t *)((char *)base + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)base + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)base + OFF_A);

    printf("\n╔══════════════════════════════════════════════╗\n");
    printf("║       Memory Subsystem Stress Test           ║\n");
    printf("╚══════════════════════════════════════════════╝\n");

    /* NOP to initialize trace_id_prev */
    uint64_t a, b;
    build_trace(7, 15, 0, 0, 0, 0, &a, &b);
    send_trace(a, b);
    usleep(500);

    test1_data_patterns();
    test2_back_to_back_ddr3();
    test3_raw_chains();
    test4_tlb_pressure();
    test5_cross_set_l2();
    test6_overwrite_and_verify();
    test7_iteration_stress();

    printf("\n═══════════════════════════════════════════════\n");
    printf("  PASS: %d  |  FAIL: %d  |  TIMEOUT: %d\n",
           total_pass, total_fail, total_timeout);
    printf("═══════════════════════════════════════════════\n");

    if (total_fail == 0 && total_timeout == 0)
        printf("\n  >>> ALL TESTS PASSED <<<\n\n");
    else
        printf("\n  >>> SOME TESTS FAILED <<<\n\n");

    munmap(base, H2F_SPAN);
    close(fd);
    return (total_fail > 0 || total_timeout > 0) ? 1 : 0;
}
