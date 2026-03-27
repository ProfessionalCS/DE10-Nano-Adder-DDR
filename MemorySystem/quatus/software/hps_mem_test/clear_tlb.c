/*
 * clear_tlb.c — Evict all entries from the 16-entry fully-associative DTLB.
 *
 * Fills the TLB with 16 unique dummy pages at high addresses, replacing
 * every existing entry via Tree-PLRU replacement.  After this, all
 * previous vaddr->paddr mappings are gone — subsequent loads or stores
 * to old virtual addresses will TLB-miss.
 *
 * TLB geometry (from dtlb.sv):
 *   16 entries, fully-associative, Tree-PLRU replacement
 *   Page size: 4 KB  (PAGE_OFF = 12)
 *   VPN: 36 bits (48-12)   PPN: 18 bits (30-12)
 *
 * Build:  gcc -O2 -o clear_tlb clear_tlb.c
 * Usage:  ./clear_tlb [num_entries]
 *         Default: 16 (evicts all entries)
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

/* ── Trace opcodes ──────────────────────────────────────────────────── */
#define OP_LOAD     0
#define OP_TLB_FILL 4

/* ── TLB geometry ───────────────────────────────────────────────────── */
#define TLB_ENTRIES 16

/* ── Dummy page base (near top of 30-bit paddr space — won't conflict) */
#define DUMMY_BASE  0x3F000000ULL

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

/* ═════════════════════════════════════════════════════════════════════ */
int main(int argc, char **argv)
{
    int count = TLB_ENTRIES;
    if (argc >= 2)
        count = atoi(argv[1]);
    if (count < 1)            count = 1;
    if (count > TLB_ENTRIES)  count = TLB_ENTRIES;

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

    printf("=== TLB Clear ===\n");
    printf("DTLB: %d entries, fully-associative, Tree-PLRU\n", TLB_ENTRIES);
    printf("Evicting %d entr%s with dummy pages\n\n",
           count, count == 1 ? "y" : "ies");

    /*
     * Fill TLB with dummy pages starting at DUMMY_BASE (0x3F000000).
     * These are near the top of the 1 GB physical address space and
     * will not collide with any typical mapping.
     * Identity-mapped: vaddr == paddr.
     *
     * After 16 fills, every TLB slot holds one of our dummy pages.
     * All previous virtual->physical translations are gone.
     */
    for (int i = 0; i < count; i++) {
        uint64_t page  = DUMMY_BASE + (uint64_t)i * 0x1000ULL;
        uint64_t paddr = page & 0x3FFFFFFFULL;   /* 30-bit physical */
        uint64_t a, b;

        build_trace(OP_TLB_FILL, nid(), page, 1, paddr, 0, &a, &b);
        send_trace(a, b);
        usleep(300);

        printf("  [%2d] TLB fill: vpage 0x%09llx -> paddr 0x%08llx\n",
               i, (unsigned long long)(page >> 12),
               (unsigned long long)paddr);
    }

    printf("\n=== TLB Clear Complete ===\n");
    printf("All %d TLB entries now hold dummy pages (0x3F000xxx .. 0x3F00Fxxx).\n",
           count);
    printf("Old virtual->physical mappings are gone.\n");
    printf("New operations will need fresh TLB fills before they can proceed.\n");

    munmap(base, H2F_SPAN);
    close(fd);
    return 0;
}
