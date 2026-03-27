/*
 * mem_test.c — HPS-side driver for the FPGA memory subsystem
 *
 * Drives the LSQ → TLB → L1 → L2 → DDR3 hierarchy via three 64-bit PIOs
 * that are connected through the HPS h2f AXI bridge (base 0xC0000000):
 *
 *   adder_sum  (read,  pio64_in_0)  @ offset 0x00   FPGA → HPS
 *   adder_b    (write, pio64_out_1) @ offset 0x08   HPS → FPGA
 *   adder_a    (write, pio64_out_0) @ offset 0x10   HPS → FPGA
 *
 * Trace encoding (121-bit trace_line):
 *   trace_line[120:0] = { adder_b[56:0], adder_a[63:0] }
 *
 *   adder_a[47:0]  = trace_vaddr
 *   adder_a[51:48] = trace_id
 *   adder_a[54:52] = trace_op         (0=LOAD, 1=STORE, 2=RESOLVE, 4=TLB_FILL)
 *   adder_a[55]    = vaddr_is_valid
 *   adder_a[63:56] = trace_value[7:0]
 *   adder_b[55:0]  = trace_value[63:8]
 *   adder_b[56]    = value_is_valid
 *
 * Status readback (adder_sum):
 *   [29:0]  = obs_cache_ret_data[29:0]
 *   [59:30] = obs_wb_addr[29:0]
 *   [60]    = obs_l2_req_valid
 *   [61]    = obs_wb_valid
 *
 * LED[0] = obs_cache_ret_valid  (blinks when cache returns data)
 *
 * Build:  arm-linux-gnueabihf-gcc -O2 -o mem_test mem_test.c
 * Usage:
 *   ./mem_test smoke                        # quick TLB fill + load test
 *   ./mem_test trace <file.bin> [delay_us]  # replay a binary trace
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

/* ------------------------------------------------------------------ */
/* HPS address map (Cyclone V)                                        */
/* ------------------------------------------------------------------ */
#define H2F_BASE        0xC0000000   /* HPS-to-FPGA AXI bridge        */
#define H2F_SPAN        0x00001000   /* map 4 KB (more than enough)    */

/* Offsets of the PIOs inside mm_bridge_0 (from soc_system.qsys)      */
#define OFF_ADDER_SUM   0x00   /* pio64_in_0  (FPGA→HPS, read)        */
#define OFF_ADDER_B     0x08   /* pio64_out_1 (HPS→FPGA, write)       */
#define OFF_ADDER_A     0x10   /* pio64_out_0 (HPS→FPGA, write)       */

/* ------------------------------------------------------------------ */
/* Trace opcodes (must match cacheDataTypes.sv / op_e)                 */
/* ------------------------------------------------------------------ */
#define OP_MEM_LOAD     0
#define OP_MEM_STORE    1
#define OP_MEM_RESOLVE  2
#define OP_TLB_FILL     4

#define TRACE_RECORD_SIZE 16

/* ------------------------------------------------------------------ */
/* Helpers                                                             */
/* ------------------------------------------------------------------ */
static volatile uint64_t *reg_sum;   /* read  */
static volatile uint64_t *reg_b;     /* write */
static volatile uint64_t *reg_a;     /* write */

/*
 * Write a 121-bit trace line to the FPGA.
 *
 * IMPORTANT: Write adder_b FIRST, then adder_a.  The LSQ triggers a
 * new operation when trace_id (inside adder_a) changes, so adder_b
 * must already hold the correct value before adder_a is written.
 */
static void send_trace(uint64_t a, uint64_t b)
{
    *reg_b = b;
    __asm__ __volatile__("dsb" ::: "memory");   /* data-sync barrier */
    *reg_a = a;
    __asm__ __volatile__("dsb" ::: "memory");
}

/*
 * Build adder_a / adder_b from the five trace fields.
 */
static void build_trace(uint8_t op, uint8_t id, uint64_t vaddr,
                        int vaddr_valid, uint64_t value, int value_valid,
                        uint64_t *a_out, uint64_t *b_out)
{
    uint64_t a = 0, b = 0;

    a |= (vaddr & 0xFFFFFFFFFFFFULL);                /* [47:0]  vaddr     */
    a |= ((uint64_t)(id   & 0xF))  << 48;            /* [51:48] id        */
    a |= ((uint64_t)(op   & 0x7))  << 52;            /* [54:52] op        */
    a |= ((uint64_t)(vaddr_valid ? 1 : 0)) << 55;    /* [55]    vaddr_val */
    a |= (value & 0xFF) << 56;                        /* [63:56] val[7:0]  */

    b |= (value >> 8) & 0x00FFFFFFFFFFFFFFULL;        /* [55:0]  val[63:8] */
    b |= ((uint64_t)(value_valid ? 1 : 0)) << 56;     /* [56]    val_valid */

    *a_out = a;
    *b_out = b;
}

static uint64_t read_status(void)
{
    return *reg_sum;
}

/* Clear the sticky status bits by writing the all-1s sentinel to adder_b */
static void clear_status(void)
{
    *reg_b = 0xFFFFFFFFFFFFFFFEULL;   /* bits[63:57]=1111111, triggers clear */
    __asm__ __volatile__("dsb" ::: "memory");
    *reg_b = 0;                        /* clear the sentinel so it doesn't persist */
    __asm__ __volatile__("dsb" ::: "memory");
}

static void print_status(const char *tag)
{
    uint64_t s = read_status();
    /* New sticky bit layout (after DE10_NANO_SoC_GHRD.v fix):
     *   bit 63 : ever cache_ret_valid (L1 returned data to LSQ)
     *   bit 62 : ever l2_req_valid    (L1 miss fired → L2 request)
     *   bit 61 : ever wb_valid        (dirty writeback from L1)
     *   bit 60 : reserved
     *   59:30  : wb_addr at last writeback
     *   29:0   : cache_ret_data[29:0] at last cache return
     */
    uint32_t ret_data      = (uint32_t)(s & 0x3FFFFFFF);
    uint32_t wb_addr       = (uint32_t)((s >> 30) & 0x3FFFFFFF);
    int      wb_seen       = (int)((s >> 61) & 1);
    int      l2_req_seen   = (int)((s >> 62) & 1);
    int      cache_seen    = (int)((s >> 63) & 1);

    printf("[%s] status=0x%016llx  ret_data=0x%08x  wb_addr=0x%08x  "
           "l2_miss_seen=%d  wb_seen=%d  cache_ret_seen=%d\n",
           tag, (unsigned long long)s, ret_data, wb_addr,
           l2_req_seen, wb_seen, cache_seen);
}

/* ------------------------------------------------------------------ */
/* Smoke test: TLB fill + simple load                                  */
/* ------------------------------------------------------------------ */
static void smoke_test(void)
{
    uint64_t a, b;

    printf("=== Smoke Test ===\n");
    clear_status();            /* reset all sticky bits before starting */
    print_status("before");

    /* 1. Clear: write a NOP-like line (op=7 unused, id=15) to set trace_id_prev */
    build_trace(7, 15, 0, 0, 0, 0, &a, &b);
    send_trace(a, b);
    usleep(1000);

    /* 2. TLB fill: vaddr page 0x001000 → paddr 0x00001 (PPN in [85:56]=paddr[29:0]) */
    /*    For TLB_FILL, the paddr is in trace_value[29:0] = trace_line[85:56]         */
    /*    fill_tlb_paddr = trace_line[85:56]                                           */
    /*    fill_tlb_vaddr = trace_line[47:0]                                            */
    printf("Sending TLB_FILL: vaddr_page=0x001000, paddr=0x00001000\n");
    build_trace(OP_TLB_FILL, 0, 0x001000, 1, 0x00001000ULL, 0, &a, &b);
    send_trace(a, b);
    usleep(1000);
    print_status("post-tlb-fill");

    /* 3. Load from vaddr 0x001008, id=1 (different from previous id=0)              */
    /*    The TLB should translate page 0x001xxx → paddr 0x00001xxx                  */
    printf("Sending LOAD: id=1, vaddr=0x001008\n");
    build_trace(OP_MEM_LOAD, 1, 0x001008, 1, 0, 0, &a, &b);
    send_trace(a, b);

    /* Wait for the cache hierarchy to process */
    for (int i = 0; i < 10; i++) {
        usleep(1000);
        print_status("wait");
    }

    /* 4. Another load to same cache line, id=2 (should be L1 hit) */
    printf("Sending LOAD: id=2, vaddr=0x001010 (same cache line — expect L1 hit)\n");
    build_trace(OP_MEM_LOAD, 2, 0x001010, 1, 0, 0, &a, &b);
    send_trace(a, b);

    for (int i = 0; i < 5; i++) {
        usleep(1000);
        print_status("hit?");
    }

    /* 5. Store test: write a known value, id=3 */
    printf("Sending STORE: id=3, vaddr=0x001020, value=0xDEADBEEF\n");
    build_trace(OP_MEM_STORE, 3, 0x001020, 1, 0xDEADBEEFULL, 1, &a, &b);
    send_trace(a, b);

    for (int i = 0; i < 5; i++) {
        usleep(1000);
        print_status("store");
    }

    /* 6. Load back the stored value, id=4 */
    printf("Sending LOAD: id=4, vaddr=0x001020 (read back the store)\n");
    build_trace(OP_MEM_LOAD, 4, 0x001020, 1, 0, 0, &a, &b);
    send_trace(a, b);

    for (int i = 0; i < 10; i++) {
        usleep(1000);
        print_status("load-back");
    }

    printf("=== Smoke Test Done ===\n");
    printf("If status changed and LED[0] flickered, the subsystem is alive.\n");
}

/* ------------------------------------------------------------------ */
/* Trace replay: feed a binary .bin trace file                         */
/* ------------------------------------------------------------------ */
static void replay_trace(const char *path, int delay_us)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return; }

    uint8_t buf[TRACE_RECORD_SIZE];
    int n = 0;
    uint64_t a, b;

    printf("=== Replaying trace: %s  (delay=%d us) ===\n", path, delay_us);
    clear_status();            /* reset sticky bits before replaying */
    print_status("start");

    while (fread(buf, TRACE_RECORD_SIZE, 1, f) == 1) {
        /*
         * Binary trace format (little-endian, 16 bytes):
         *   bytes[0..5]  = vaddr[47:0]
         *   byte[6]      = { vaddr_valid[7], op[6:4], id[3:0] }
         *   bytes[7..14] = value[63:0]
         *   byte[15]     = { 7'b0, value_valid[0] }
         */
        uint64_t vaddr = 0;
        for (int i = 0; i < 6; i++)
            vaddr |= ((uint64_t)buf[i]) << (i * 8);

        uint8_t  id         = buf[6] & 0x0F;
        uint8_t  op         = (buf[6] >> 4) & 0x07;
        uint8_t  vaddr_val  = (buf[6] >> 7) & 0x01;

        uint64_t value = 0;
        for (int i = 0; i < 8; i++)
            value |= ((uint64_t)buf[7 + i]) << (i * 8);

        uint8_t val_val = buf[15] & 0x01;

        build_trace(op, id, vaddr, vaddr_val, value, val_val, &a, &b);
        send_trace(a, b);

        n++;
        if (delay_us > 0)
            usleep(delay_us);

        /* Print periodic status */
        if (n % 500 == 0) {
            printf("  [%d records sent] ", n);
            print_status("progress");
        }
    }

    printf("  Total records sent: %d\n", n);

    /* Let the pipeline drain */
    printf("  Draining pipeline...\n");
    for (int i = 0; i < 20; i++) {
        usleep(5000);
        print_status("drain");
    }

    fclose(f);
    printf("=== Trace Replay Done ===\n");
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */
int main(int argc, char *argv[])
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem (need root)"); return 1; }

    void *base = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, H2F_BASE);
    if (base == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    /* Set up volatile pointers to the three 64-bit PIOs */
    reg_sum = (volatile uint64_t *)((char *)base + OFF_ADDER_SUM);
    reg_b   = (volatile uint64_t *)((char *)base + OFF_ADDER_B);
    reg_a   = (volatile uint64_t *)((char *)base + OFF_ADDER_A);

    if (argc < 2) {
        printf("Usage:\n");
        printf("  %s smoke                       — quick TLB + load/store test\n", argv[0]);
        printf("  %s trace <file.bin> [delay_us] — replay a binary trace\n", argv[0]);
        printf("  %s status                      — read current status register\n", argv[0]);
        munmap(base, H2F_SPAN);
        close(fd);
        return 0;
    }

    if (strcmp(argv[1], "smoke") == 0) {
        smoke_test();
    } else if (strcmp(argv[1], "trace") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Need trace file path\n");
        } else {
            int delay = (argc >= 4) ? atoi(argv[3]) : 100;
            replay_trace(argv[2], delay);
        }
    } else if (strcmp(argv[1], "status") == 0) {
        print_status("now");
    } else {
        fprintf(stderr, "Unknown command: %s\n", argv[1]);
    }

    munmap(base, H2F_SPAN);
    close(fd);
    return 0;
}
