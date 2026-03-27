/*
 * manual_test.c — Interactive store/load correctness checker for the
 *                 FPGA memory subsystem (LSQ → TLB → L1 → L2 → DDR3).
 *
 * Automatically manages TLB fills: in "clean" mode it fills the TLB page
 * before every access; in "dirty" mode it assumes the TLB is already
 * populated from a previous run.
 *
 * Keeps a local shadow memory so loads can be verified against expected
 * values.  Prints PASS/FAIL for every load, plus which cache level served
 * the data (L1 / L2 / DDR3) using sticky status bits.
 *
 * Build (on DE10-Nano):
 *   gcc -O2 -o manual_test manual_test.c
 *
 * Usage:
 *   ./manual_test <clean|dirty> store <vaddr> <data>
 *   ./manual_test <clean|dirty> load  <vaddr>
 *   ./manual_test <clean|dirty> test               — built-in correctness suite
 *   ./manual_test verify <trace.bin> [addr ...]    — verify trace stores
 *   ./manual_test status                            — read sticky status
 *   ./manual_test clear                             — clear sticky status
 *
 * Examples:
 *   ./manual_test clean store 0x1008 0xDEADBEEF
 *   ./manual_test dirty load  0x1008
 *   ./manual_test clean test
 *   ./manual_test verify dgemm3_lsq88.bin           — verify all stores
 *   ./manual_test verify dgemm3_lsq88.bin 0x1008    — verify one address
 *
 * All addresses are virtual; the TLB identity-maps vpage → ppage.
 * Addresses must be 8-byte aligned (bottom 3 bits = 0).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ── HPS address map ─────────────────────────────────────────────────── */
#define H2F_BASE        0xC0000000
#define H2F_SPAN        0x00001000
#define OFF_SUM         0x00
#define OFF_B           0x08
#define OFF_A           0x10

/* ── Trace opcodes ───────────────────────────────────────────────────── */
#define OP_LOAD         0
#define OP_STORE        1
#define OP_TLB_FILL     4

/* ── Shadow memory (simple hash table for verifying loads) ───────────── */
#define SHADOW_BUCKETS  4096

typedef struct shadow_entry {
    uint64_t addr;
    uint64_t data;
    struct shadow_entry *next;
} shadow_entry_t;

static shadow_entry_t *shadow[SHADOW_BUCKETS];

static void shadow_store(uint64_t addr, uint64_t data)
{
    unsigned h = (unsigned)(addr >> 3) % SHADOW_BUCKETS;
    shadow_entry_t *e = shadow[h];
    while (e) {
        if (e->addr == addr) { e->data = data; return; }
        e = e->next;
    }
    e = malloc(sizeof(*e));
    e->addr = addr;
    e->data = data;
    e->next = shadow[h];
    shadow[h] = e;
}

static int shadow_lookup(uint64_t addr, uint64_t *data_out)
{
    unsigned h = (unsigned)(addr >> 3) % SHADOW_BUCKETS;
    shadow_entry_t *e = shadow[h];
    while (e) {
        if (e->addr == addr) { *data_out = e->data; return 1; }
        e = e->next;
    }
    return 0;
}

/* ── Hardware I/O ────────────────────────────────────────────────────── */
static volatile uint64_t *reg_sum, *reg_b, *reg_a;
static int fd_mem;
static void *map_base;

static int hw_init(void)
{
    fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem < 0) { perror("open /dev/mem"); return -1; }
    map_base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                    MAP_SHARED, fd_mem, H2F_BASE);
    if (map_base == MAP_FAILED) { perror("mmap"); close(fd_mem); return -1; }
    reg_sum = (volatile uint64_t *)((char *)map_base + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)map_base + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)map_base + OFF_A);
    return 0;
}

static void hw_cleanup(void)
{
    munmap(map_base, H2F_SPAN);
    close(fd_mem);
}

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
    *a |= ((uint64_t)(id  & 0xF))  << 48;
    *a |= ((uint64_t)(op  & 0x7))  << 52;
    *a |= ((uint64_t)(vv ? 1 : 0)) << 55;
    *a |= (value & 0xFF) << 56;
    *b  = (value >> 8) & 0x00FFFFFFFFFFFFFFULL;
    *b |= ((uint64_t)(val_v ? 1 : 0)) << 56;
}

static void clear_status(void)
{
    *reg_a = 0; dsb();                    /* neutralise stale TLB_FILL op before touching reg_b */
    *reg_b = 0xFFFFFFFFFFFFFFFEULL; dsb();
    *reg_b = 0; dsb();
}

static uint64_t read_status(void) { return *reg_sum; }

/* Determine cache level name from status bits */
static const char *cache_level_str(uint64_t s)
{
    int l2_miss = (int)((s >> 62) & 1);
    int ddr3    = (int)((s >> 60) & 1);
    int cret    = (int)((s >> 63) & 1);
    if (!cret) return "???";
    if (!l2_miss) return "\033[32mL1\033[0m";
    if (!ddr3)    return "\033[33mL2\033[0m";
    return "\033[31mDDR3\033[0m";
}

static void print_status(const char *tag)
{
    uint64_t s = read_status();
    uint32_t ret  = (uint32_t)(s & 0x3FFFFFFF);
    uint32_t wba  = (uint32_t)((s >> 30) & 0x07FFFFFF);  /* wb_addr[26:0] */
    int wb   = (int)((s >> 61) & 1);
    int l2   = (int)((s >> 62) & 1);
    int ddr3 = (int)((s >> 60) & 1);
    int cret = (int)((s >> 63) & 1);
    int avm_rd   = (int)((s >> 59) & 1);  /* Avalon read asserted */
    int avm_acc  = (int)((s >> 58) & 1);  /* Avalon beat accepted (!waitrequest) */
    int avm_dv   = (int)((s >> 57) & 1);  /* Avalon readdatavalid */
    printf("[%s] ret=0x%08x  level=%s  l2_miss=%d ddr3=%d wb=%d cache_ret=%d"
           "  avm(rd=%d acc=%d dv=%d)\n",
           tag, ret, cache_level_str(s), l2, ddr3, wb, cret,
           avm_rd, avm_acc, avm_dv);
}

/* ── Trace ID management (must change between operations) ────────────── */
static uint8_t next_id = 1;

static uint8_t get_id(void)
{
    uint8_t id = next_id;
    next_id = (next_id + 1) & 0xF;
    if (next_id == 0) next_id = 1;  /* skip 0 to keep transition visible */
    return id;
}

/* ── TLB page tracking (match HW TLB capacity: 16 entries, PLRU) ───── */
#define HW_TLB_ENTRIES  16            /* must match dtlb.sv NUM_ENTRIES */
#define MAX_PAGES       HW_TLB_ENTRIES
static uint64_t filled_pages[MAX_PAGES];
static int num_filled = 0;
static int fill_ptr   = 0;           /* circular pointer for FIFO eviction */

static int page_filled(uint64_t page)
{
    for (int i = 0; i < num_filled; i++)
        if (filled_pages[i] == page) return 1;
    return 0;
}

static void fill_tlb_page(uint64_t vaddr)
{
    uint64_t page = vaddr & ~0xFFFULL;   /* zero the 12-bit offset */
    if (page_filled(page)) return;

    /* Identity map: vpage → same ppage (paddr = vaddr for simplicity) */
    /* fill_tlb_paddr = trace_line[85:56] = value[29:0] */
    uint64_t paddr = page & 0x3FFFFFFFULL;  /* 30-bit paddr */
    uint64_t a, b;
    build_trace(OP_TLB_FILL, 0, page, 1, paddr, 0, &a, &b);
    send_trace(a, b);
    usleep(500);

    /* Track in FIFO ring matching HW TLB capacity */
    if (num_filled < MAX_PAGES) {
        filled_pages[num_filled++] = page;
    } else {
        filled_pages[fill_ptr] = page;
        fill_ptr = (fill_ptr + 1) % MAX_PAGES;
    }

    printf("  [TLB] filled page vaddr=0x%06llx → paddr=0x%08llx\n",
           (unsigned long long)page, (unsigned long long)paddr);
}

/* ── Core operations ─────────────────────────────────────────────────── */

static void do_store(uint64_t vaddr, uint64_t data, int clean)
{
    if (clean) fill_tlb_page(vaddr);

    uint8_t id = get_id();
    uint64_t a, b;
    clear_status();
    build_trace(OP_STORE, id, vaddr, 1, data, 1, &a, &b);
    send_trace(a, b);
    usleep(2000);

    shadow_store(vaddr, data);
    print_status("STORE");
    printf("  STORE id=%u vaddr=0x%012llx data=0x%016llx → OK (saved to shadow)\n",
           id, (unsigned long long)vaddr, (unsigned long long)data);
}

static void do_load(uint64_t vaddr, int clean)
{
    if (clean) fill_tlb_page(vaddr);

    uint8_t id = get_id();
    uint64_t a, b;
    clear_status();
    build_trace(OP_LOAD, id, vaddr, 1, 0, 0, &a, &b);
    send_trace(a, b);

    /* Poll for cache_ret_valid (bit 63) */
    uint64_t s = 0;
    for (int i = 0; i < 100; i++) {
        usleep(500);
        s = read_status();
        if ((s >> 63) & 1) break;
    }

    uint32_t ret30 = (uint32_t)(s & 0x3FFFFFFF);
    int got_ret = (int)((s >> 63) & 1);

    if (!got_ret) {
        printf("  LOAD id=%u vaddr=0x%012llx → TIMEOUT (no cache_ret_valid)\n",
               id, (unsigned long long)vaddr);
        print_status("LOAD");
        return;
    }

    const char *level = cache_level_str(s);

    /* Check against shadow memory */
    uint64_t expected;
    if (shadow_lookup(vaddr, &expected)) {
        uint32_t exp30 = (uint32_t)(expected & 0x3FFFFFFF);
        if (ret30 == exp30) {
            printf("  LOAD id=%u vaddr=0x%012llx → ret=0x%08x  expected=0x%08x  [%s]  \033[32mPASS\033[0m\n",
                   id, (unsigned long long)vaddr, ret30, exp30, level);
        } else {
            printf("  LOAD id=%u vaddr=0x%012llx → ret=0x%08x  expected=0x%08x  [%s]  \033[31mFAIL\033[0m\n",
                   id, (unsigned long long)vaddr, ret30, exp30, level);
        }
    } else {
        printf("  LOAD id=%u vaddr=0x%012llx → ret=0x%08x  [%s]  (no shadow, DDR3 residual)\n",
               id, (unsigned long long)vaddr, ret30, level);
    }
    print_status("LOAD");
}

/* ── Built-in correctness suite ──────────────────────────────────────── */
static void run_test(int clean)
{
    int pass = 0, fail = 0;
    printf("\n=== Correctness Test Suite (mode=%s) ===\n\n", clean ? "clean" : "dirty");

    /* Reset starting ID so each test run is deterministic */
    next_id = 1;
    num_filled = 0;
    fill_ptr   = 0;

    /* --- Test 1: Basic store/load --------------------------------------- */
    printf("[Test 1] Basic store + load\n");
    do_store(0x1008, 0xCAFEBABE, clean);
    do_load(0x1008, clean);

    /* --- Test 2: Different word in same cache line ---------------------- */
    printf("\n[Test 2] Another word in same cache line\n");
    do_store(0x1010, 0x12345678, clean);
    do_load(0x1010, clean);

    /* --- Test 3: Store overwrites previous ----------------------------- */
    printf("\n[Test 3] Overwrite previous value\n");
    do_store(0x1008, 0xAAAAAAAA, clean);
    do_load(0x1008, clean);

    /* --- Test 4: Different page --------------------------------------- */
    printf("\n[Test 4] Different page (0x2000)\n");
    do_store(0x2020, 0xDEADBEEF, clean);
    do_load(0x2020, clean);

    /* --- Test 5: Rapid multi-address ---------------------------------- */
    printf("\n[Test 5] Rapid multi-address stores then loads\n");
    uint64_t addrs[] = {0x3000, 0x3008, 0x3010, 0x3018};
    uint64_t vals[]  = {0x100, 0x200, 0x300, 0x400};
    for (int i = 0; i < 4; i++)
        do_store(addrs[i], vals[i], clean);
    for (int i = 0; i < 4; i++)
        do_load(addrs[i], clean);

    /* --- Test 6: Cross-page (L1 conflict) ------------------------------ */
    printf("\n[Test 6] Cross-page accesses (eviction test)\n");
    for (int p = 4; p < 12; p++) {
        uint64_t addr = (uint64_t)p * 0x1000 + 0x40;
        do_store(addr, 0xF000 + p, clean);
    }
    for (int p = 4; p < 12; p++) {
        uint64_t addr = (uint64_t)p * 0x1000 + 0x40;
        do_load(addr, clean);
    }

    /* --- Test 7: DDR3 exercise (overflow both L1 + L2) ----------------- *
     * L1 = 2-way, 4-set (8 lines). L2 = 4-way, 4-set (16 lines).
     * All addresses below have paddr[7:6]=00 → same L2 set 0.
     * After 4 stores the L2 set is full; stores 5+ evict to DDR3.
     * Then loading back an early address forces L1 miss + L2 miss → DDR3.
     *
     * We use 20 pages (0x10000..0x23000 step 0x1000) to be thorough.
     * Each page stores at offset 0x00 so paddr[7:6]=00 always.           */
    printf("\n[Test 7] DDR3 exercise (20 pages, force L2 eviction → DDR3 fetch)\n");
    #define DDR3_PAGES 20
    #define DDR3_BASE  0x10000ULL
    for (int i = 0; i < DDR3_PAGES; i++) {
        uint64_t addr = DDR3_BASE + (uint64_t)i * 0x1000;
        do_store(addr, 0xDD000 + i, clean);
    }
    printf("  --- Now loading back early pages (expect DDR3 level) ---\n");
    for (int i = 0; i < DDR3_PAGES; i++) {
        uint64_t addr = DDR3_BASE + (uint64_t)i * 0x1000;
        do_load(addr, clean);
    }

    /* --- Test 8: Load to never-stored address -------------------------- *
     * Issues a load to an address that was never stored to.
     * Should still complete (return DDR3 residual, not hang).
     * Verifies the memory subsystem handles "cold" reads gracefully.      */
    printf("\n[Test 8] Load to never-stored address (cold read)\n");
    printf("  Expect: completes with DDR3 residual data, no match.\n");
    do_load(0x3F008, clean);

    /* --- Summary ------------------------------------------------------- */
    /* Re-check all shadow entries that we loaded */
    printf("\n=== Test Suite Complete ===\n");
    printf("Check PASS/FAIL above for each load.\n");
    printf("If all loads show PASS, the memory subsystem is correct.\n\n");
}

/* ── Trace file parsing ─────────────────────────────────────────────── */
/* Load a .bin trace file and build shadow memory from all STORE records.
 * Also records TLB fills so we know which pages are mapped.             */

/* ── Trace TLB mapping table (vpage → paddr from TLB_FILL records) ─── */
#define MAX_TLB_MAP 256
static struct { uint64_t vpage; uint64_t paddr; } tlb_map[MAX_TLB_MAP];
static int num_tlb_map = 0;

static void record_tlb_map(uint64_t vpage, uint64_t paddr)
{
    /* update existing or insert new */
    for (int i = 0; i < num_tlb_map; i++) {
        if (tlb_map[i].vpage == vpage) {
            tlb_map[i].paddr = paddr;
            return;
        }
    }
    if (num_tlb_map < MAX_TLB_MAP) {
        tlb_map[num_tlb_map].vpage = vpage;
        tlb_map[num_tlb_map].paddr = paddr;
        num_tlb_map++;
    }
}

static int lookup_tlb_map(uint64_t vpage, uint64_t *paddr_out)
{
    for (int i = 0; i < num_tlb_map; i++) {
        if (tlb_map[i].vpage == vpage) {
            *paddr_out = tlb_map[i].paddr;
            return 1;
        }
    }
    return 0;
}

/* Send a TLB fill using the trace's own vaddr→paddr mapping.
 * ALWAYS sends the fill (no caching) so the hardware TLB is fresh.     */
static void fill_tlb_for_load(uint64_t vaddr)
{
    uint64_t page = vaddr & ~0xFFFULL;
    uint64_t paddr;
    if (!lookup_tlb_map(page, &paddr))
        paddr = page & 0x3FFFFFFFULL;   /* identity map fallback */

    uint64_t a, b;
    uint8_t fid = get_id();
    build_trace(OP_TLB_FILL, fid, page, 1, paddr, 0, &a, &b);
    send_trace(a, b);
    usleep(300);
}

/* Collected store addresses for verify-all */
#define MAX_STORE_ADDRS 8192
static uint64_t store_addrs[MAX_STORE_ADDRS];
static int      num_store_addrs = 0;

static void record_store_addr(uint64_t addr)
{
    for (int i = 0; i < num_store_addrs; i++)
        if (store_addrs[i] == addr) return;
    if (num_store_addrs < MAX_STORE_ADDRS)
        store_addrs[num_store_addrs++] = addr;
}

/* Parse the trace file in software only: build shadow memory and TLB map.
 * Does NOT touch the hardware.  Call this after mem_test has already
 * replayed the trace so the cache/DDR3 have real state.                  */
static int parse_trace_software(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return -1; }

    uint8_t buf[16];
    int n_total = 0, n_stores = 0, n_tlb = 0, n_loads = 0;

    while (fread(buf, 16, 1, f) == 1) {
        uint64_t vaddr = 0;
        for (int i = 0; i < 6; i++)
            vaddr |= ((uint64_t)buf[i] << (i * 8));

        uint8_t byte6 = buf[6];
        uint8_t op    = (byte6 >> 4) & 0x07;

        uint64_t value = 0;
        for (int i = 0; i < 8; i++)
            value |= ((uint64_t)buf[7 + i] << (i * 8));

        n_total++;

        if (op == OP_STORE) {
            shadow_store(vaddr, value);
            record_store_addr(vaddr);
            n_stores++;
        } else if (op == OP_TLB_FILL) {
            uint64_t page  = vaddr & ~0xFFFULL;
            uint64_t paddr = value & 0x3FFFFFFFULL;
            record_tlb_map(page, paddr);
            n_tlb++;
        } else if (op == OP_LOAD) {
            n_loads++;
        }
    }
    fclose(f);

    printf("Trace: %s\n", path);
    printf("  Records: %d total  |  %d stores  |  %d loads  |  %d TLB fills\n",
           n_total, n_stores, n_loads, n_tlb);
    printf("  Unique store addrs: %d  |  TLB pages: %d\n",
           num_store_addrs, num_tlb_map);
    return 0;
}

/* --- Single hardware verification load -------------------------------- */
static void verify_one(uint64_t vaddr, int idx)
{
    /* Always send a fresh TLB fill right before the load so the hardware
     * TLB definitely has the correct mapping (only 16 entries in HW).   */
    fill_tlb_for_load(vaddr);

    uint8_t id = get_id();
    uint64_t a, b;
    clear_status();
    build_trace(OP_LOAD, id, vaddr, 1, 0, 0, &a, &b);
    send_trace(a, b);

    /* Poll for cache_ret_valid (bit 63) — up to 50 ms */
    uint64_t s = 0;
    for (int t = 0; t < 100; t++) {
        usleep(500);
        s = read_status();
        if ((s >> 63) & 1) break;
    }

    uint32_t ret30  = (uint32_t)(s & 0x3FFFFFFF);
    int got_ret     = (int)((s >> 63) & 1);
    const char *lvl = got_ret ? cache_level_str(s) : "---";

    uint64_t expected;
    if (!got_ret) {
        printf("  [%4d] 0x%012llx  TIMEOUT\n",
               idx, (unsigned long long)vaddr);
        return;
    }
    if (shadow_lookup(vaddr, &expected)) {
        uint32_t exp30 = (uint32_t)(expected & 0x3FFFFFFF);
        if (ret30 == exp30)
            printf("  [%4d] 0x%012llx  ret=0x%08x  exp=0x%08x  [%s]  \033[32mPASS\033[0m\n",
                   idx, (unsigned long long)vaddr, ret30, exp30, lvl);
        else
            printf("  [%4d] 0x%012llx  ret=0x%08x  exp=0x%08x  [%s]  \033[31mFAIL\033[0m\n",
                   idx, (unsigned long long)vaddr, ret30, exp30, lvl);
    } else {
        printf("  [%4d] 0x%012llx  ret=0x%08x  [%s]  (no shadow)\n",
               idx, (unsigned long long)vaddr, ret30, lvl);
    }
}

/* Verify mode — usage:
 *   ./manual_test verify <trace.bin>                        -- show stats only
 *   ./manual_test verify <trace.bin> <addr> [addr ...]     -- spot-check addrs
 *   ./manual_test verify <trace.bin> all                   -- all store addrs
 *
 * Assumes the trace has already been replayed via `mem_test trace`.      */
static void do_verify(const char *trace_path, int argc, char *argv[], int addr_start)
{
    /* Step 1: parse trace in software — builds shadow + TLB map, no HW */
    if (parse_trace_software(trace_path) < 0) return;

    if (addr_start >= argc) {
        /* No addresses given — just print stats and a sample */
        printf("\nNo addresses specified. Run with address args to verify.\n");
        printf("Example: ./manual_test verify %s 0x7fff10a1f768\n", trace_path);
        printf("         ./manual_test verify %s all   (check all %d stores)\n",
               trace_path, num_store_addrs);
        return;
    }

    /* Step 2: initialize trace_id */
    {
        uint64_t a, b;
        build_trace(7, 15, 0, 0, 0, 0, &a, &b);
        send_trace(a, b);
        usleep(500);
    }

    printf("\n=== Verification Loads ===\n\n");

    int pass = 0, fail = 0, timeout = 0;

    /* "all" keyword: check every unique store address */
    if (strcmp(argv[addr_start], "all") == 0) {
        printf("Checking all %d stored addresses...\n\n", num_store_addrs);
        for (int i = 0; i < num_store_addrs; i++) {
            verify_one(store_addrs[i], i);

            /* Count results from last line printed — re-read status */
            uint64_t s = read_status();
            int got = (int)((s >> 63) & 1);
            if (!got) { timeout++; continue; }
            uint32_t ret30 = (uint32_t)(s & 0x3FFFFFFF);
            uint64_t expected;
            if (shadow_lookup(store_addrs[i], &expected)) {
                if (ret30 == (uint32_t)(expected & 0x3FFFFFFF)) pass++;
                else fail++;
            }
        }
        printf("\n=== Results: %d PASS  %d FAIL  %d TIMEOUT (of %d) ===\n",
               pass, fail, timeout, num_store_addrs);
    } else {
        /* Specific addresses from command line */
        for (int i = addr_start; i < argc; i++)
            verify_one(strtoull(argv[i], NULL, 0), i - addr_start);
    }
}

/* ── Main ──────────────────────────────────────────────────────────── */
int main(int argc, char *argv[])
{
    if (argc < 2) {
        printf("Usage:\n");
        printf("  %s <clean|dirty> store <vaddr> <data>  — write to FPGA memory\n", argv[0]);
        printf("  %s <clean|dirty> load  <vaddr>         — read from FPGA memory\n", argv[0]);
        printf("  %s <clean|dirty> test                  — run correctness suite\n", argv[0]);
        printf("  %s verify <trace.bin>              — show trace stats\n", argv[0]);
        printf("  %s verify <trace.bin> all          — verify all stores\n", argv[0]);
        printf("  %s verify <trace.bin> <addr> [...] — spot-check addresses\n", argv[0]);
        printf("  %s status                          — read sticky status\n", argv[0]);
        printf("  %s clear                           — clear sticky status\n", argv[0]);
        printf("\n  clean = TLB-fill the page automatically\n");
        printf("  dirty = assume TLB already populated (from prior run/trace)\n");
        printf("\n  verify: parse trace to get expected values, then load + compare.\n");
        printf("          Run 'mem_test trace <file> 10' first, then verify.\n");
        printf("\n  LED indicators: L1 hit (LED0), L2 hit (LED1), DDR3 (LED2).\n");
        return 0;
    }

    if (hw_init() < 0) return 1;

    /* Handle status/clear without mode arg */
    if (strcmp(argv[1], "status") == 0) {
        print_status("now");
        hw_cleanup();
        return 0;
    }
    if (strcmp(argv[1], "clear") == 0) {
        clear_status();
        printf("Status cleared.\n");
        hw_cleanup();
        return 0;
    }

    /* Handle verify mode: ./manual_test verify <trace.bin> [addr ...] */
    if (strcmp(argv[1], "verify") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: %s verify <trace.bin> [addr ...]\n", argv[0]);
            hw_cleanup(); return 1;
        }
        do_verify(argv[2], argc, argv, 3);
        hw_cleanup();
        return 0;
    }

    /* Parse mode */
    if (argc < 3) {
        fprintf(stderr, "Need <clean|dirty> <command> ...\n");
        hw_cleanup();
        return 1;
    }

    int clean;
    if (strcmp(argv[1], "clean") == 0 || strcmp(argv[1], "0") == 0)
        clean = 1;
    else if (strcmp(argv[1], "dirty") == 0 || strcmp(argv[1], "1") == 0)
        clean = 0;
    else {
        fprintf(stderr, "First arg must be 'clean' (or 0) or 'dirty' (or 1)\n");
        hw_cleanup();
        return 1;
    }

    const char *cmd = argv[2];

    /* Initialize trace_id by sending a NOP to set trace_id_prev */
    {
        uint64_t a, b;
        build_trace(7, 15, 0, 0, 0, 0, &a, &b);
        send_trace(a, b);
        usleep(500);
    }

    if (strcmp(cmd, "store") == 0) {
        if (argc < 5) {
            fprintf(stderr, "Usage: %s <mode> store <vaddr> <data>\n", argv[0]);
            hw_cleanup(); return 1;
        }
        uint64_t vaddr = strtoull(argv[3], NULL, 0);
        uint64_t data  = strtoull(argv[4], NULL, 0);
        do_store(vaddr, data, clean);

    } else if (strcmp(cmd, "load") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: %s <mode> load <vaddr>\n", argv[0]);
            hw_cleanup(); return 1;
        }
        uint64_t vaddr = strtoull(argv[3], NULL, 0);
        do_load(vaddr, clean);

    } else if (strcmp(cmd, "test") == 0) {
        run_test(clean);

    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
    }

    hw_cleanup();
    return 0;
}
