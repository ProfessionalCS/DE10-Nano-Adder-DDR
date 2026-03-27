/*
 * true_stress_test.c -- Indiscriminate load sweep to thrash L1/L2 caches.
 *
 * This is intentionally broad, unlike ddr3_test's precise conflict pattern.
 * It walks many pages and every 64-byte line in each page so previously
 * touched lines are very likely evicted from both L1 and L2.
 *
 * Typical usage after a manual direct-map store:
 *   ./fpga_manual reset
 *   ./fpga_manual tlb_fill 0x38001000 0x38001000
 *   ./fpga_manual store 1 0x38001020 0x12345678
 *   ./true_stress_test
 *   devmem2 0x38001020 w
 *
 * Build: gcc -O2 -o true_stress_test true_stress_test.c
 * Run:   ./true_stress_test [base_addr] [pages] [rounds]
 *
 * Defaults:
 *   base_addr = 0x38400000
 *   pages     = 256
 *   rounds    = 2
 *
 * Total loads issued = pages * 64 * rounds.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
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

#define BIT_CACHE_RET 63
#define BIT_L1_MISS   62
#define BIT_L2_REQ    60
#define BIT_AVM_READ  59
#define BIT_AVM_ACC   58
#define BIT_AVM_DV    57

#define PAGE_SIZE_BYTES   0x1000ULL
#define LINE_SIZE_BYTES   0x40ULL
#define LINES_PER_PAGE    64

#define DEFAULT_BASE_ADDR 0x38400000ULL
#define DEFAULT_PAGES     256
#define DEFAULT_ROUNDS    2

static volatile uint64_t *reg_sum, *reg_b, *reg_a;
static uint8_t next_id = 1;

static void dsb(void) { __asm__ __volatile__("dsb" ::: "memory"); }

static void send_trace(uint64_t a, uint64_t b)
{
    *reg_b = b;
    dsb();
    *reg_a = a;
    dsb();
}

static void build_trace(uint8_t op, uint8_t id, uint64_t vaddr,
                        int vaddr_valid, uint64_t value, int value_valid,
                        uint64_t *a_out, uint64_t *b_out)
{
    uint64_t a = 0, b = 0;

    a |= (vaddr & 0xFFFFFFFFFFFFULL);
    a |= ((uint64_t)(id & 0xF)) << 48;
    a |= ((uint64_t)(op & 0x7)) << 52;
    a |= ((uint64_t)(vaddr_valid ? 1u : 0u)) << 55;
    a |= (value & 0xFFULL) << 56;

    b |= (value >> 8) & 0x00FFFFFFFFFFFFFFULL;
    b |= ((uint64_t)(value_valid ? 1u : 0u)) << 56;

    *a_out = a;
    *b_out = b;
}

static void clear_status(void)
{
    *reg_b = 0xFFFFFFFFFFFFFFFEULL;
    dsb();
    *reg_b = 0;
    dsb();
}

static uint8_t nid(void)
{
    uint8_t id = next_id;
    next_id = (next_id >= 15) ? 1 : (uint8_t)(next_id + 1);
    return id;
}

static int bit(uint64_t status, int n)
{
    return (int)((status >> n) & 1ULL);
}

static void seed_trace_id(void)
{
    uint64_t a, b;
    build_trace(7, 15, 0, 0, 0, 0, &a, &b);
    send_trace(a, b);
    usleep(500);
}

static void tlb_fill(uint64_t page_addr)
{
    uint64_t a, b;
    uint64_t page = page_addr & ~(PAGE_SIZE_BYTES - 1ULL);
    uint64_t paddr = page & 0x3FFFFFFFULL;
    build_trace(OP_TLB_FILL, nid(), page, 1, paddr, 0, &a, &b);
    send_trace(a, b);
    usleep(300);
}

static uint64_t load_once(uint64_t vaddr, int *timed_out)
{
    uint64_t a, b, status = 0;

    clear_status();
    build_trace(OP_LOAD, nid(), vaddr, 1, 0, 0, &a, &b);
    send_trace(a, b);

    for (int poll = 0; poll < 200; poll++) {
        usleep(500);
        status = *reg_sum;
        if (bit(status, BIT_CACHE_RET)) {
            *timed_out = 0;
            return status;
        }
    }

    *timed_out = 1;
    return *reg_sum;
}

static void usage(const char *prog)
{
    printf("Usage: %s [base_addr] [pages] [rounds]\n", prog);
    printf("  base_addr  start address for the load sweep (default 0x%08llx)\n",
           (unsigned long long)DEFAULT_BASE_ADDR);
    printf("  pages      number of 4 KB pages to sweep (default %d)\n", DEFAULT_PAGES);
    printf("  rounds     how many full sweeps to run (default %d)\n", DEFAULT_ROUNDS);
}

int main(int argc, char **argv)
{
    uint64_t base_addr = DEFAULT_BASE_ADDR;
    int pages = DEFAULT_PAGES;
    int rounds = DEFAULT_ROUNDS;
    uint64_t total_loads = 0;
    uint64_t total_timeouts = 0;
    uint64_t total_l1_misses = 0;
    uint64_t total_l2_reqs = 0;
    uint64_t total_avm_reads = 0;
    uint64_t total_avm_accepts = 0;
    uint64_t total_avm_dv = 0;

    if (argc >= 2)
        base_addr = strtoull(argv[1], NULL, 0);
    if (argc >= 3)
        pages = atoi(argv[2]);
    if (argc >= 4)
        rounds = atoi(argv[3]);
    if (argc >= 5 || pages <= 0 || rounds <= 0) {
        usage(argv[0]);
        return 1;
    }

    base_addr &= ~(PAGE_SIZE_BYTES - 1ULL);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                      MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    reg_sum = (volatile uint64_t *)((char *)base + OFF_SUM);
    reg_b   = (volatile uint64_t *)((char *)base + OFF_B);
    reg_a   = (volatile uint64_t *)((char *)base + OFF_A);

    printf("\n=============================================\n");
    printf(" True Stress Test: broad cache-thrash loads\n");
    printf("=============================================\n");
    printf("  base_addr = 0x%08llx\n", (unsigned long long)base_addr);
    printf("  pages     = %d\n", pages);
    printf("  rounds    = %d\n", rounds);
    printf("  loads     = %llu\n\n",
           (unsigned long long)((uint64_t)pages * LINES_PER_PAGE * (uint64_t)rounds));

    seed_trace_id();

    for (int round = 0; round < rounds; round++) {
        printf("[round %d/%d]\n", round + 1, rounds);

        for (int page_idx = 0; page_idx < pages; page_idx++) {
            uint64_t page = base_addr + (uint64_t)page_idx * PAGE_SIZE_BYTES;
            tlb_fill(page);

            for (int line = 0; line < LINES_PER_PAGE; line++) {
                int timed_out = 0;
                uint64_t vaddr = page + (uint64_t)line * LINE_SIZE_BYTES;
                uint64_t status = load_once(vaddr, &timed_out);

                total_loads++;
                total_timeouts += (uint64_t)timed_out;
                total_l1_misses += (uint64_t)bit(status, BIT_L1_MISS);
                total_l2_reqs += (uint64_t)bit(status, BIT_L2_REQ);
                total_avm_reads += (uint64_t)bit(status, BIT_AVM_READ);
                total_avm_accepts += (uint64_t)bit(status, BIT_AVM_ACC);
                total_avm_dv += (uint64_t)bit(status, BIT_AVM_DV);
            }

            if (((page_idx + 1) % 32) == 0 || page_idx == pages - 1) {
                printf("  pages done: %d/%d  loads=%llu  timeouts=%llu\n",
                       page_idx + 1, pages,
                       (unsigned long long)total_loads,
                       (unsigned long long)total_timeouts);
            }
        }
    }

    printf("\nSummary\n");
    printf("  total_loads   = %llu\n", (unsigned long long)total_loads);
    printf("  timeouts      = %llu\n", (unsigned long long)total_timeouts);
    printf("  l1_miss_seen  = %llu\n", (unsigned long long)total_l1_misses);
    printf("  l2_req_seen   = %llu\n", (unsigned long long)total_l2_reqs);
    printf("  avm_read_seen = %llu\n", (unsigned long long)total_avm_reads);
    printf("  avm_acc_seen  = %llu\n", (unsigned long long)total_avm_accepts);
    printf("  avm_dv_seen   = %llu\n", (unsigned long long)total_avm_dv);
    printf("\nBroad sweep complete. This does not prove correctness by itself.\n");
    printf("Use it after a manual store, then verify the physical address with devmem2.\n");

    munmap(base, H2F_SPAN);
    close(fd);
    return (total_timeouts != 0) ? 1 : 0;
}
