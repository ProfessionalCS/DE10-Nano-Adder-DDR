#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <string.h>

static void msg(const char *s) { write(STDERR_FILENO, s, strlen(s)); }

int main() {
    char buf[128];
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { msg("ERR: open /dev/mem\n"); return 1; }
    msg("opened /dev/mem\n");

    /* Read brgmodrst */
    volatile uint32_t *rst = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, 0xFFD05000);
    if (rst == MAP_FAILED) { msg("ERR: mmap rstmgr\n"); return 1; }
    snprintf(buf, sizeof(buf), "brgmodrst=0x%08x\n", rst[0x1C/4]);
    msg(buf);
    munmap((void*)rst, 0x1000);

    /* Read sysmgr fpgaintf */
    volatile uint32_t *sys = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, 0xFFD08000);
    if (sys == MAP_FAILED) { msg("ERR: mmap sysmgr\n"); return 1; }
    snprintf(buf, sizeof(buf), "fpgaintf=0x%08x\n", sys[0x28/4]);
    msg(buf);
    munmap((void*)sys, 0x1000);

    /* Try lw h2f bridge at 0xFF200000 first (known working peripherals) */
    msg("try lw_h2f 0xFF200000...\n");
    volatile uint32_t *lw = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xFF200000);
    if (lw == MAP_FAILED) { msg("ERR: mmap lw_h2f\n"); return 1; }
    snprintf(buf, sizeof(buf), "lw[0x3000/4]=0x%08x (led_pio)\n", lw[0x3000/4]);
    msg(buf);
    munmap((void*)lw, 0x10000);

    /* Try h2f bridge at 0xC0000000 */
    msg("try h2f 0xC0000000...\n");
    volatile uint32_t *h2f = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xC0000000);
    if (h2f == MAP_FAILED) { msg("ERR: mmap h2f\n"); return 1; }
    msg("mmap h2f OK, reading [0]...\n");
    uint32_t val = h2f[0];
    snprintf(buf, sizeof(buf), "h2f[0]=0x%08x\n", val);
    msg(buf);
    munmap((void*)h2f, 0x1000);

    close(fd);
    msg("ALL OK\n");
    return 0;
}
