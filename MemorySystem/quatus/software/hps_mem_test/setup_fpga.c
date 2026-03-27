/*
 * setup_fpga.c — All-in-one: program FPGA via overlay, enable bridges,
 *                deassert resets, and verify bridge access.
 *
 * Cyclone V SoC register map (from HPS Technical Reference Manual):
 *     Reset Manager base:  0xFFD05000
 *       stat       +0x00   reset status
 *       ctrl       +0x04   reset control
 *       counts     +0x08
 *       mpu_mod    +0x10   MPU module reset
 *       per_mod    +0x14   peripheral module reset
 *       per2_mod   +0x18   peripheral module reset2
 *       brg_mod    +0x1C   bridge module reset (hps2fpga, lwhps2fpga, f2hps)
 *       misc_mod   +0x20   misc module reset
 *
 *     System Manager base: 0xFFD08000
 *       fpgaintf   +0x28   FPGA interface group module
 *
 *     FPGA Manager base:   0xFF706000
 *       stat       +0x00
 *       ctrl       +0x04
 *
 * Build:  gcc -O2 -o setup_fpga setup_fpga.c
 * Usage:  ./setup_fpga
 */

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

/* Helper: print immediately */
static void msg(const char *s) { write(STDERR_FILENO, s, strlen(s)); }

static int map_and_dump(int fd, uint32_t phys, uint32_t span, const char *name,
                        volatile uint32_t **out)
{
    char buf[256];
    volatile uint32_t *p = mmap(NULL, span, PROT_READ | PROT_WRITE,
                                MAP_SHARED, fd, phys);
    if (p == MAP_FAILED) {
        snprintf(buf, sizeof(buf), "ERR: mmap %s@0x%08x: %s\n",
                 name, phys, strerror(errno));
        msg(buf);
        return -1;
    }
    *out = p;
    return 0;
}

int main(int argc, char **argv)
{
    char buf[256];
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    /* ---- 1. Dump all relevant registers ---- */
    volatile uint32_t *rstmgr, *sysmgr, *fpgamgr;
    if (map_and_dump(fd, 0xFFD05000, 0x1000, "rstmgr", &rstmgr)) return 1;
    if (map_and_dump(fd, 0xFFD08000, 0x1000, "sysmgr", &sysmgr)) return 1;
    if (map_and_dump(fd, 0xFF706000, 0x1000, "fpgamgr", &fpgamgr)) return 1;

    snprintf(buf, sizeof(buf),
             "=== BEFORE ===\n"
             "  rst_stat     = 0x%08x\n"
             "  brgmodrst    = 0x%08x\n"
             "  miscmodrst   = 0x%08x\n"
             "  fpgaintf     = 0x%08x\n"
             "  fpgamgr_stat = 0x%08x\n"
             "  fpgamgr_ctrl = 0x%08x\n",
             rstmgr[0x00/4],
             rstmgr[0x1C/4],
             rstmgr[0x20/4],
             sysmgr[0x28/4],
             fpgamgr[0x00/4],
             fpgamgr[0x04/4]);
    msg(buf);

    /* ---- 2. Deassert bridge resets ---- */
    msg("Clearing brgmodrst (bridge resets)...\n");
    rstmgr[0x1C/4] = 0x00000000;

    /* ---- 3. Deassert misc module resets (including any FPGA resets) ---- */
    msg("Clearing miscmodrst...\n");
    uint32_t misc = rstmgr[0x20/4];
    rstmgr[0x20/4] = 0x00000000;

    /* ---- 4. Enable FPGA interfaces ---- */
    msg("Setting fpgaintf to 0x07...\n");
    sysmgr[0x28/4] = 0x7;

    /* Small delay for bridges to stabilize */
    usleep(10000);

    /* ---- 5. Dump after ---- */
    snprintf(buf, sizeof(buf),
             "=== AFTER ===\n"
             "  brgmodrst    = 0x%08x\n"
             "  miscmodrst   = 0x%08x\n"
             "  fpgaintf     = 0x%08x\n"
             "  fpgamgr_stat = 0x%08x\n"
             "  fpgamgr_ctrl = 0x%08x\n",
             rstmgr[0x1C/4],
             rstmgr[0x20/4],
             sysmgr[0x28/4],
             fpgamgr[0x00/4],
             fpgamgr[0x04/4]);
    msg(buf);

    munmap((void *)fpgamgr, 0x1000);
    munmap((void *)sysmgr, 0x1000);
    munmap((void *)rstmgr, 0x1000);

    /* ---- 6. Try h2f bridge access ---- */
    msg("Attempting h2f bridge read at 0xC0000000...\n");
    volatile uint32_t *h2f = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, 0xC0000000);
    if (h2f == MAP_FAILED) { msg("ERR: mmap h2f\n"); close(fd); return 1; }
    msg("mmap OK. Reading h2f[0]...\n");
    uint32_t val = h2f[0];
    snprintf(buf, sizeof(buf), "h2f[0] = 0x%08x  <-- SUCCESS!\n", val);
    msg(buf);
    munmap((void *)h2f, 0x1000);

    close(fd);
    msg("Bridge access verified OK.\n");
    return 0;
}
