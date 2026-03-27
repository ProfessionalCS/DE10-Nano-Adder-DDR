#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

static void msg(const char *s) { write(STDERR_FILENO, s, strlen(s)); }

int main() {
    char buf[256];

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { msg("ERR: open /dev/mem\n"); return 1; }

    /* ---- L3 Regs (0xFF800000) ---- */
    volatile uint32_t *l3 = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFF800000);
    if (l3 == MAP_FAILED) { msg("ERR: mmap l3\n"); return 1; }
    snprintf(buf, sizeof(buf), "L3 remap      = 0x%08x\n", l3[0x00/4]);
    msg(buf);
    /* Set h2f and lwhps2fpga remap bits */
    uint32_t old_remap = l3[0x00/4];
    l3[0x00/4] = old_remap | 0x18;  /* bits 3=h2f visible, bit 4=lwhps2fpga visible */
    snprintf(buf, sizeof(buf), "L3 remap  set = 0x%08x\n", l3[0x00/4]);
    msg(buf);

    /* ---- L3 GPV security (base + 0x8000) ---- */
    /* h2f security at offset 0x8094 */
    snprintf(buf, sizeof(buf), "L3 h2f security   = 0x%08x\n", l3[0x8094/4]);
    msg(buf);
    snprintf(buf, sizeof(buf), "L3 lw_h2f security = 0x%08x\n", l3[0x8098/4]);
    msg(buf);

    munmap((void*)l3, 0x10000);

    /* ---- Reset Manager ---- */
    volatile uint32_t *rst = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFFD05000);
    if (rst == MAP_FAILED) { msg("ERR: mmap rst\n"); return 1; }
    snprintf(buf, sizeof(buf), "brgmodrst     = 0x%08x\n", rst[0x1C/4]);
    msg(buf);
    /* Ensure all bridge resets clear */
    rst[0x1C/4] = 0;
    snprintf(buf, sizeof(buf), "brgmodrst now = 0x%08x\n", rst[0x1C/4]);
    msg(buf);
    munmap((void*)rst, 0x1000);

    /* ---- System Manager ---- */
    volatile uint32_t *sys = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFFD08000);
    if (sys == MAP_FAILED) { msg("ERR: mmap sys\n"); return 1; }
    snprintf(buf, sizeof(buf), "fpgaintf      = 0x%08x\n", sys[0x28/4]);
    msg(buf);
    /* Enable all interfaces */
    sys[0x28/4] = 0xFFFFFFFF;
    snprintf(buf, sizeof(buf), "fpgaintf now  = 0x%08x\n", sys[0x28/4]);
    msg(buf);
    munmap((void*)sys, 0x1000);

    /* ---- FPGA Manager ---- */
    volatile uint32_t *fpga = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, 0xFF706000);
    if (fpga == MAP_FAILED) { msg("ERR: mmap fpgamgr\n"); return 1; }
    snprintf(buf, sizeof(buf), "fpga_status   = 0x%08x\n", fpga[0x00/4]);
    msg(buf);
    snprintf(buf, sizeof(buf), "fpga_ctrl     = 0x%08x\n", fpga[0x04/4]);
    msg(buf);
    munmap((void*)fpga, 0x1000);

    /* ---- SDRAM Controller: take F2SDRAM ports out of reset (0xFFC25080) ---- */
    volatile uint32_t *sdr = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFFC25000);
    if (sdr == MAP_FAILED) { msg("ERR: mmap sdr\n"); return 1; }
    snprintf(buf, sizeof(buf), "fpgaportrst   = 0x%08x\n", sdr[0x80/4]);
    msg(buf);
    /* Enable all F2SDRAM ports (write 1 = out of reset) */
    sdr[0x80/4] = 0x3FFF;
    snprintf(buf, sizeof(buf), "fpgaportrst now = 0x%08x\n", sdr[0x80/4]);
    msg(buf);
    munmap((void*)sdr, 0x1000);

    /* ---- Now try h2f bridge ---- */
    msg("Attempting h2f read at 0xC0000000...\n");
    volatile uint32_t *h2f = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xC0000000);
    if (h2f == MAP_FAILED) { msg("ERR: mmap h2f\n"); return 1; }
    msg("mmap OK, reading...\n");
    uint32_t val = h2f[0];
    snprintf(buf, sizeof(buf), "h2f[0]=0x%08x SUCCESS!\n", val);
    msg(buf);

    munmap((void*)h2f, 0x1000);
    close(fd);
    msg("DONE\n");
    return 0;
}
