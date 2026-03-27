/*
 * tlb_evict.c -- Fill enough unique pages to evict one page from the DTLB.
 *
 * The hardware DTLB is 16-entry PLRU. This tool:
 *   1. TLB-fills the target page
 *   2. TLB-fills 16 other unique pages
 *   3. Optionally probes the target with a LOAD without re-filling it
 *
 * Build on board: gcc -O2 -o tlb_evict tlb_evict.c
 * Usage:          ./tlb_evict <target_page> [probe_vaddr]
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define H2F_BASE    0xC0000000
#define H2F_SPAN    0x00001000
#define OFF_SUM     0x00
#define OFF_B       0x08
#define OFF_A       0x10

#define OP_LOAD     0
#define OP_TLB_FILL 4

#define TLB_ENTRIES 16   /* must match dtlb.sv NUM_ENTRIES */

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
    *reg_a = 0; dsb();
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

static void probe_load(uint64_t vaddr)
{
    uint64_t a, b;
    clear_status();
    build_trace(OP_LOAD, nid(), vaddr, 1, 0, 0, &a, &b);
    send_trace(a, b);

    for (int i = 0; i < 40; i++) {
        usleep(500);
        if (((*reg_sum >> 63) & 1ULL) != 0) {
            printf("Probe LOAD returned data: status=0x%016llx\n",
                   (unsigned long long)*reg_sum);
            return;
        }
    }

    printf("Probe LOAD produced no cache return. Target page is likely evicted from TLB.\n");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <target_page> [probe_vaddr]\n", argv[0]);
        return 1;
    }

    uint64_t target_page = strtoull(argv[1], NULL, 0) & ~0xFFFULL;
    uint64_t probe_vaddr = (argc >= 3) ? strtoull(argv[2], NULL, 0) : target_page;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    reg_sum = (volatile uint64_t *)((char *)base + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)base + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)base + OFF_A);

    /* Seed trace_id_prev */
    {
        uint64_t a, b;
        build_trace(7, 15, 0, 0, 0, 0, &a, &b);
        send_trace(a, b);
        usleep(500);
    }

    printf("Filling target page: 0x%llx\n", (unsigned long long)target_page);
    tlb_fill(target_page);

    for (int i = 1; i <= TLB_ENTRIES; i++) {
        uint64_t page = target_page + (uint64_t)i * 0x1000ULL;
        if (page == target_page)
            page += 0x1000ULL;
        tlb_fill(page);
    }

    printf("Filled %d additional pages. Target page should now be evicted.\n", TLB_ENTRIES);
    probe_load(probe_vaddr);

    munmap(base, H2F_SPAN);
    close(fd);
    return 0;
}
