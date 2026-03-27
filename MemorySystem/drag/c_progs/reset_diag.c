#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>

/* Cyclone V HPS Reset Manager */
#define RSTMGR_BASE     0xFFD05000
#define RSTMGR_SPAN     0x100
#define BRGMODRST_OFF   0x1C    /* Bridge Module Reset Register */
#define MISCMODRST_OFF  0x20    /* Misc Module Reset Register */
#define STAT_OFF        0x00    /* Status Register */

/* FPGA Manager */
#define FPGAMGR_BASE    0xFF706000
#define FPGAMGR_SPAN    0x100
#define FPGAMGR_STAT    0x00    /* Status */
#define FPGAMGR_CTRL    0x04    /* Control */
#define FPGAMGR_DCLKCNT 0x08

/* H2F bridge */
#define H2F_BASE        0xC0000000
#define H2F_SPAN        0x1000

int main(int argc, char **argv) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }

    /* Map reset manager */
    volatile uint32_t *rstmgr = mmap(NULL, RSTMGR_SPAN, PROT_READ | PROT_WRITE,
                                      MAP_SHARED, fd, RSTMGR_BASE);
    if (rstmgr == MAP_FAILED) { perror("mmap rstmgr"); return 1; }

    /* Map FPGA manager */
    volatile uint32_t *fpgamgr = mmap(NULL, FPGAMGR_SPAN, PROT_READ | PROT_WRITE,
                                       MAP_SHARED, fd, FPGAMGR_BASE);
    if (fpgamgr == MAP_FAILED) { perror("mmap fpgamgr"); return 1; }

    /* Map H2F bridge */
    volatile uint64_t *h2f = mmap(NULL, H2F_SPAN, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, fd, H2F_BASE);
    if (h2f == MAP_FAILED) { perror("mmap h2f"); return 1; }

    printf("=== Reset/FPGA Manager Diagnostic ===\n\n");

    /* Read reset manager registers */
    uint32_t stat = rstmgr[STAT_OFF / 4];
    uint32_t brg  = rstmgr[BRGMODRST_OFF / 4];
    uint32_t misc = rstmgr[MISCMODRST_OFF / 4];
    printf("RSTMGR:\n");
    printf("  STATUS    = 0x%08X\n", stat);
    printf("  BRGMODRST = 0x%08X  (bit0=h2f, bit1=lwh2f, bit2=f2h)\n", brg);
    printf("  MISCMODRST= 0x%08X\n", misc);

    /* Read FPGA manager registers */
    uint32_t fstat = fpgamgr[FPGAMGR_STAT / 4];
    uint32_t fctrl = fpgamgr[FPGAMGR_CTRL / 4];
    printf("\nFPGAMGR:\n");
    printf("  STATUS = 0x%08X  mode=%d\n", fstat, fstat & 0x7);
    printf("  CTRL   = 0x%08X\n", fctrl);

    /* Read H2F PIOs before reset fix */
    printf("\nH2F PIO reads (before fix):\n");
    printf("  [0x00] = 0x%016llX\n", (unsigned long long)h2f[0]);

    /* If bridge resets are asserted, clear them */
    if (brg & 0x7) {
        printf("\n** Bridge resets are asserted! Clearing...\n");
        rstmgr[BRGMODRST_OFF / 4] = brg & ~0x7;
        usleep(1000);
        printf("  BRGMODRST now = 0x%08X\n", rstmgr[BRGMODRST_OFF / 4]);
        printf("  H2F [0x00] now = 0x%016llX\n", (unsigned long long)h2f[0]);
    }

    /* If we got --fix, also try other reset tricks */
    if (argc > 1 && strcmp(argv[1], "--fix") == 0) {
        printf("\n-- Attempting fix: clear BRGMODRST fully --\n");
        rstmgr[BRGMODRST_OFF / 4] = 0;
        usleep(10000);
        printf("  BRGMODRST = 0x%08X\n", rstmgr[BRGMODRST_OFF / 4]);

        /* Also try to control FPGA manager ctrl register */
        printf("  FPGAMGR CTRL = 0x%08X\n", fpgamgr[FPGAMGR_CTRL / 4]);

        /* Read PIO again */
        printf("  H2F [0x00] = 0x%016llX\n", (unsigned long long)h2f[0]);
    }

    printf("\n=== Done ===\n");

    munmap((void *)rstmgr, RSTMGR_SPAN);
    munmap((void *)fpgamgr, FPGAMGR_SPAN);
    munmap((void *)h2f, H2F_SPAN);
    close(fd);
    return 0;
}
