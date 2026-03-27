/*
 * fpga_manual.c — Manual command-line interface for the FPGA memory subsystem
 *
 * Sends individual operations (tlb_fill, load, store, resolve) to the
 * LSQ → TLB → L1 → L2 → DDR3 hierarchy and reads back status.
 *
 * Build (on DE10-Nano):
 *   gcc -O2 -o fpga_manual fpga_manual.c
 *
 * Usage:
 *   ./fpga_manual status
 *   ./fpga_manual tlb_fill <vaddr_page> <paddr>
 *   ./fpga_manual load     <id> <vaddr>
 *   ./fpga_manual store    <id> <vaddr> <value>
 *   ./fpga_manual resolve  <id> <vaddr> <value> [vv] [dv]
 *   ./fpga_manual reset
 *
 * Examples:
 *   ./fpga_manual tlb_fill 0x1000 0x00001000
 *   ./fpga_manual load 1 0x1008
 *   ./fpga_manual store 2 0x1020 0xDEADBEEF
 *   ./fpga_manual resolve 3 0x2000 0 1 0
 *   ./fpga_manual status
 *
 * All numeric arguments accept hex (0x prefix) or decimal.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* HPS-to-FPGA bridge */
#define H2F_BASE        0xC0000000
#define H2F_SPAN        0x00001000

/* Reset manager — assert/deassert FPGA bridge resets */
#define RSTMGR_BASE     0xFFD05000
#define RSTMGR_SPAN     0x00001000
#define BRGMODRST_OFF   0x1C       /* bridge module reset register */
/* bit 0 = h2f, bit 1 = lwhps2fpga, bit 2 = fpga2hps */

/* PIO offsets (from Qsys) */
#define OFF_ADDER_SUM   0x00   /* read:  FPGA → HPS  */
#define OFF_ADDER_B     0x08   /* write: HPS → FPGA  */
#define OFF_ADDER_A     0x10   /* write: HPS → FPGA  */

/* Operation codes (must match cacheDataTypes.sv / op_e) */
#define OP_MEM_LOAD     0
#define OP_MEM_STORE    1
#define OP_MEM_RESOLVE  2
#define OP_TLB_FILL     4

static volatile uint64_t *reg_sum;
static volatile uint64_t *reg_b;
static volatile uint64_t *reg_a;
static void *map_base;
static int fd_mem;

/* ------------------------------------------------------------------ */
/* Hardware I/O                                                        */
/* ------------------------------------------------------------------ */
static int hw_init(void)
{
    fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd_mem < 0) {
        perror("open /dev/mem (run as root)");
        return -1;
    }
    map_base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                    MAP_SHARED, fd_mem, H2F_BASE);
    if (map_base == MAP_FAILED) {
        perror("mmap h2f bridge");
        close(fd_mem);
        return -1;
    }
    reg_sum = (volatile uint64_t *)((char *)map_base + OFF_ADDER_SUM);
    reg_b   = (volatile uint64_t *)((char *)map_base + OFF_ADDER_B);
    reg_a   = (volatile uint64_t *)((char *)map_base + OFF_ADDER_A);
    return 0;
}

static void hw_cleanup(void)
{
    munmap(map_base, H2F_SPAN);
    close(fd_mem);
}

static void send_trace(uint64_t a, uint64_t b)
{
    *reg_b = b;
    __asm__ __volatile__("dsb" ::: "memory");
    *reg_a = a;
    __asm__ __volatile__("dsb" ::: "memory");
}

static void build_trace(uint8_t op, uint8_t id, uint64_t vaddr,
                        int vaddr_valid, uint64_t value, int value_valid,
                        uint64_t *a_out, uint64_t *b_out)
{
    uint64_t a = 0, b = 0;
    a |= (vaddr & 0xFFFFFFFFFFFFULL);
    a |= ((uint64_t)(id   & 0xF))  << 48;
    a |= ((uint64_t)(op   & 0x7))  << 52;
    a |= ((uint64_t)(vaddr_valid ? 1 : 0)) << 55;
    a |= (value & 0xFF) << 56;

    b |= (value >> 8) & 0x00FFFFFFFFFFFFFFULL;
    b |= ((uint64_t)(value_valid ? 1 : 0)) << 56;

    *a_out = a;
    *b_out = b;
}

/* ------------------------------------------------------------------ */
/* Status readback                                                     */
/* ------------------------------------------------------------------ */
static void print_status(void)
{
    uint64_t s = *reg_sum;
    uint32_t ret_data   = (uint32_t)(s & 0x3FFFFFFF);
    uint32_t wb_addr    = (uint32_t)((s >> 30) & 0x3FFFFFFF);
    int      l2_req_val = (int)((s >> 60) & 1);
    int      wb_val     = (int)((s >> 61) & 1);

    printf("Status: 0x%016llx\n", (unsigned long long)s);
    printf("  ret_data [29:0]  = 0x%08x  (%u)\n", ret_data, ret_data);
    printf("  wb_addr  [59:30] = 0x%08x\n", wb_addr);
    printf("  l2_req_valid     = %d\n", l2_req_val);
    printf("  wb_valid         = %d\n", wb_val);
}

/* Poll status until it changes from 'before' value, or timeout */
static void wait_for_change(uint64_t before, int polls, int delay_us)
{
    for (int i = 0; i < polls; i++) {
        usleep(delay_us);
        uint64_t cur = *reg_sum;
        if (cur != before) {
            printf("  [changed after %d ms]\n", (i + 1) * delay_us / 1000);
            print_status();
            return;
        }
    }
    printf("  [no change after %d ms — reading current status]\n",
           polls * delay_us / 1000);
    print_status();
}

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */
static uint64_t parse_num(const char *s)
{
    return strtoull(s, NULL, 0);  /* handles 0x hex and decimal */
}

static void cmd_status(void)
{
    print_status();
}

static void cmd_tlb_fill(uint64_t vaddr_page, uint64_t paddr)
{
    uint64_t a, b;
    printf("TLB_FILL: vaddr_page=0x%llx  paddr=0x%llx\n",
           (unsigned long long)vaddr_page, (unsigned long long)paddr);

    build_trace(OP_TLB_FILL, 0, vaddr_page, 1, paddr, 0, &a, &b);
    send_trace(a, b);
    usleep(1000);
    printf("  Sent. ");
    print_status();
}

static void cmd_load(uint8_t id, uint64_t vaddr)
{
    uint64_t a, b;
    printf("LOAD: id=%d  vaddr=0x%llx\n", id, (unsigned long long)vaddr);

    uint64_t before = *reg_sum;  /* snapshot BEFORE sending */
    build_trace(OP_MEM_LOAD, id, vaddr, 1, 0, 0, &a, &b);
    send_trace(a, b);
    printf("  Sent. Waiting for response...\n");
    wait_for_change(before, 50, 1000);
}

static void cmd_store(uint8_t id, uint64_t vaddr, uint64_t value)
{
    uint64_t a, b;
    printf("STORE: id=%d  vaddr=0x%llx  value=0x%llx\n",
           id, (unsigned long long)vaddr, (unsigned long long)value);

    uint64_t before = *reg_sum;
    build_trace(OP_MEM_STORE, id, vaddr, 1, value, 1, &a, &b);
    send_trace(a, b);
    printf("  Sent. Waiting...\n");
    wait_for_change(before, 50, 1000);
}

static void cmd_resolve(uint8_t id, uint64_t vaddr, uint64_t value,
                        int vv, int dv)
{
    uint64_t a, b;
    printf("RESOLVE: id=%d  vaddr=0x%llx  value=0x%llx  vaddr_valid=%d  value_valid=%d\n",
           id, (unsigned long long)vaddr, (unsigned long long)value, vv, dv);

    uint64_t before = *reg_sum;
    build_trace(OP_MEM_RESOLVE, id, vaddr, vv, value, dv, &a, &b);
    send_trace(a, b);
    printf("  Sent. Waiting...\n");
    wait_for_change(before, 50, 1000);
}

static void cmd_reset(void)
{
    uint64_t a, b;

    /* Toggle h2f bridge reset via the HPS reset manager to clear all
       FPGA-side flip-flops (LSQ, caches, TLB, etc.) */
    printf("Asserting FPGA bridge reset via rstmgr...\n");
    void *rst_map = mmap(NULL, RSTMGR_SPAN, PROT_READ | PROT_WRITE,
                         MAP_SHARED, fd_mem, RSTMGR_BASE);
    if (rst_map != MAP_FAILED) {
        volatile uint32_t *brgmodrst =
            (volatile uint32_t *)((char *)rst_map + BRGMODRST_OFF);
        uint32_t orig = *brgmodrst;
        printf("  brgmodrst before = 0x%08x\n", orig);

        /* Assert reset on h2f + lwhps2fpga bridges (bits 0,1) */
        *brgmodrst = orig | 0x03;
        __asm__ __volatile__("dsb" ::: "memory");
        usleep(50000);  /* 50 ms in reset */

        /* Deassert */
        *brgmodrst = orig & ~0x03u;
        __asm__ __volatile__("dsb" ::: "memory");
        usleep(10000);  /* 10 ms settle */

        printf("  brgmodrst after  = 0x%08x\n", *brgmodrst);
        munmap(rst_map, RSTMGR_SPAN);
        printf("  FPGA logic reset done.\n");
    } else {
        perror("  mmap rstmgr failed");
    }

    /* Also send a NOP to set trace_id_prev to a known value */
    printf("Sending NOP (op=7 id=15) to seed trace_id_prev...\n");
    build_trace(7, 15, 0, 0, 0, 0, &a, &b);
    send_trace(a, b);
    usleep(1000);
    print_status();
}

/* ------------------------------------------------------------------ */
/* Usage                                                               */
/* ------------------------------------------------------------------ */
static void usage(const char *prog)
{
    printf("Usage:\n");
    printf("  %s status\n", prog);
    printf("  %s tlb_fill <vaddr_page> <paddr>\n", prog);
    printf("  %s load     <id> <vaddr>\n", prog);
    printf("  %s store    <id> <vaddr> <value>\n", prog);
    printf("  %s resolve  <id> <vaddr> <value> [vaddr_valid] [value_valid]\n", prog);
    printf("  %s reset\n", prog);
    printf("\nAll numeric args accept hex (0x...) or decimal.\n");
    printf("id range: 0-15\n");
    printf("\nExample session:\n");
    printf("  %s reset\n", prog);
    printf("  %s tlb_fill 0x1000 0x00001000\n", prog);
    printf("  %s load 1 0x1008\n", prog);
    printf("  %s store 2 0x1020 0xCAFEBABE\n", prog);
    printf("  %s load 3 0x1020              # read back the store\n", prog);
    printf("  %s status\n", prog);
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */
int main(int argc, char *argv[])
{
    if (argc < 2) {
        usage(argv[0]);
        return 1;
    }

    const char *cmd = argv[1];

    if (hw_init() < 0)
        return 1;

    if (strcmp(cmd, "status") == 0) {
        cmd_status();

    } else if (strcmp(cmd, "tlb_fill") == 0) {
        if (argc < 4) {
            fprintf(stderr, "tlb_fill requires: <vaddr_page> <paddr>\n");
            hw_cleanup();
            return 1;
        }
        cmd_tlb_fill(parse_num(argv[2]), parse_num(argv[3]));

    } else if (strcmp(cmd, "load") == 0) {
        if (argc < 4) {
            fprintf(stderr, "load requires: <id> <vaddr>\n");
            hw_cleanup();
            return 1;
        }
        cmd_load((uint8_t)parse_num(argv[2]), parse_num(argv[3]));

    } else if (strcmp(cmd, "store") == 0) {
        if (argc < 5) {
            fprintf(stderr, "store requires: <id> <vaddr> <value>\n");
            hw_cleanup();
            return 1;
        }
        cmd_store((uint8_t)parse_num(argv[2]), parse_num(argv[3]),
                  parse_num(argv[4]));

    } else if (strcmp(cmd, "resolve") == 0) {
        if (argc < 5) {
            fprintf(stderr, "resolve requires: <id> <vaddr> <value> [vaddr_valid] [value_valid]\n");
            hw_cleanup();
            return 1;
        }
        int vv = (argc > 5) ? (int)parse_num(argv[5]) : 1;
        int dv = (argc > 6) ? (int)parse_num(argv[6]) : 1;
        cmd_resolve((uint8_t)parse_num(argv[2]), parse_num(argv[3]),
                    parse_num(argv[4]), vv, dv);

    } else if (strcmp(cmd, "reset") == 0) {
        cmd_reset();

    } else {
        fprintf(stderr, "Unknown command: %s\n", cmd);
        usage(argv[0]);
        hw_cleanup();
        return 1;
    }

    hw_cleanup();
    return 0;
}
