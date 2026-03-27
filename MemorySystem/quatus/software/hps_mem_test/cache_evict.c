/*
 * cache_evict.c — Evict ALL entries from L1 and L2 caches.
 *
 * Fills every set in L1 (2-way, 4 sets) and L2 (4-way, 16 sets) with
 * garbage stores so that all previously-cached data is replaced.
 *
 * After running, devmem reads of previously-stored addresses will return
 * whatever is in DDR3 backing memory (typically uninitialized / garbage).
 *
 * Cache geometry (from RTL):
 *   L1: 2 ways x 4 sets,  set index = paddr[7:6],  tag = paddr[29:8]
 *   L2: 4 ways x 16 sets, set index = paddr[9:6],  tag = paddr[29:10]
 *   Line size: 64 bytes
 *
 * Strategy: use 6 unique 4KB pages.  Within each page, store to all 16
 * L2 set offsets (0x000, 0x040, ..., 0x3C0).  After 6 pages, every L2
 * set has been filled with 6 entries -> all 4 ways replaced by Tree-PLRU.
 * L1 (2-way) is likewise fully evicted since it sees the same addresses.
 *
 * Build:  gcc -O2 -o cache_evict cache_evict.c
 * Usage:  ./cache_evict [num_pages]
 *         Default: 6 pages (more than enough for 4-way L2)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ── H2F PIO registers ─────────────────────────────────────────────── */
#define H2F_BASE    0xC0000000
#define H2F_SPAN    0x00001000
#define OFF_SUM     0x00
#define OFF_B       0x08
#define OFF_A       0x10

/* ── Trace opcodes (must match cacheDataTypes.sv / op_e) ────────────── */
#define OP_STORE    1
#define OP_TLB_FILL 4

/* ── Cache geometry ─────────────────────────────────────────────────── */
#define L2_SETS     16
#define LINE_SIZE   64

/* ── Eviction page base (512 MB into 1 GB paddr space — safe region) ─ */
#define EVICT_BASE  0x20000000ULL

static volatile uint64_t *reg_sum, *reg_b, *reg_a;
static uint8_t next_id = 1;

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
    *a |= ((uint64_t)(id & 0xF)) << 48;
    *a |= ((uint64_t)(op & 0x7)) << 52;
    *a |= ((uint64_t)(vv ? 1u : 0u)) << 55;
    *a |= (value & 0xFFULL) << 56;
    *b  = (value >> 8) & 0x00FFFFFFFFFFFFFFULL;
    *b |= ((uint64_t)(val_v ? 1u : 0u)) << 56;
}

static uint8_t nid(void)
{
    uint8_t id = next_id;
    next_id = (next_id >= 15) ? 1 : next_id + 1;
    return id;
}

static void clear_status(void)
{
    *reg_b = 0xFFFFFFFFFFFFFFFEULL; dsb();
    *reg_b = 0; dsb();
}

static void tlb_fill(uint64_t page)
{
    uint64_t a, b;
    build_trace(OP_TLB_FILL, nid(), page, 1, page & 0x3FFFFFFFULL, 0, &a, &b);
    send_trace(a, b);
    usleep(300);
}

static void store_garbage(uint64_t vaddr, uint64_t value)
{
    uint64_t a, b;
    build_trace(OP_STORE, nid(), vaddr, 1, value, 1, &a, &b);
    send_trace(a, b);
    usleep(400);
}

/* ═════════════════════════════════════════════════════════════════════ */
int main(int argc, char **argv)
{
    int num_pages = 6;  /* 6 pages > 4 L2 ways -> guaranteed full eviction */
    if (argc >= 2)
        num_pages = atoi(argv[1]);
    if (num_pages < 1)  num_pages = 1;
    if (num_pages > 15) num_pages = 15; /* keep within TLB capacity */

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (need root)"); return 1; }

    void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    reg_sum = (volatile uint64_t *)((char *)base + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)base + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)base + OFF_A);

    /* Prime trace_id_prev with a NOP (unused opcode, id=15) */
    {
        uint64_t a, b;
        build_trace(7, 15, 0, 0, 0, 0, &a, &b);
        send_trace(a, b);
        usleep(500);
    }

    clear_status();

    printf("=== Cache Eviction ===\n");
    printf("L1: 2-way x 4 sets  |  L2: 4-way x 16 sets  |  line = 64B\n");
    printf("Filling %d pages x %d sets = %d garbage stores\n\n",
           num_pages, L2_SETS, num_pages * L2_SETS);

    /*
     * For each page:
     *   1. TLB fill (identity map: vaddr == paddr)
     *   2. Store garbage to all 16 L2 set offsets within the page
     *
     * Pages are 4 KB apart starting at EVICT_BASE (0x20000000).
     * Different pages have different L2 tags (paddr[29:10] differs),
     * so each set accumulates one new entry per page.  After 5+ pages
     * the PLRU has cycled through all 4 L2 ways -> everything evicted.
     */
    int total_stores = 0;
    for (int p = 0; p < num_pages; p++) {
        uint64_t page_base = EVICT_BASE + (uint64_t)p * 0x1000ULL;

        printf("  Page %d: 0x%08llx  ", p,
               (unsigned long long)page_base);

        tlb_fill(page_base);

        for (int s = 0; s < L2_SETS; s++) {
            uint64_t addr  = page_base + (uint64_t)s * LINE_SIZE;
            uint64_t trash = 0xDEAD000000000000ULL
                           | ((uint64_t)p << 8)
                           | (uint64_t)s;
            store_garbage(addr, trash);
            total_stores++;
        }
        printf("[%d stores done]\n", total_stores);
    }

    /* Let the pipeline drain (writebacks to DDR3 are async) */
    printf("\n  Draining pipeline...\n");
    usleep(30000);

    uint64_t status = *reg_sum;
    printf("\n  Status: 0x%016llx\n", (unsigned long long)status);
    printf("    cache_ret_seen=%d  l2_miss_seen=%d  wb_seen=%d\n",
           (int)((status >> 63) & 1),
           (int)((status >> 62) & 1),
           (int)((status >> 61) & 1));

    printf("\n=== Eviction Complete ===\n");
    printf("All L1 and L2 cache lines now contain garbage (0xDEAD...).\n");
    printf("devmem reads of old addresses will miss or return stale data.\n");

    munmap(base, H2F_SPAN);
    close(fd);
    return 0;
}
