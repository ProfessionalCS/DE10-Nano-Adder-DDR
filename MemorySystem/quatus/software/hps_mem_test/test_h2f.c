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

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { msg("ERR: open /dev/mem\n"); return 1; }
    msg("opened /dev/mem\n");

    /* Try h2f bridge at 0xC0000000 (where our PIOs are) */
    msg("mmap 0xC0000000 (h2f bridge)...\n");
    volatile uint32_t *h2f = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xC0000000);
    if (h2f == MAP_FAILED) { msg("ERR: mmap h2f\n"); return 1; }
    msg("mmap OK\n");

    msg("read h2f[0x00]...\n");
    uint32_t v0 = h2f[0x00/4];
    snprintf(buf, sizeof(buf), "h2f[0x00]=0x%08x (adder_sum low)\n", v0);
    msg(buf);

    msg("read h2f[0x04]...\n");
    uint32_t v1 = h2f[0x04/4];
    snprintf(buf, sizeof(buf), "h2f[0x04]=0x%08x (adder_sum high)\n", v1);
    msg(buf);

    msg("write h2f[0x08]=0...\n");
    h2f[0x08/4] = 0;
    msg("write OK\n");

    msg("write h2f[0x10]=0...\n");
    h2f[0x10/4] = 0;
    msg("write OK\n");

    msg("reread h2f[0x00]...\n");
    v0 = h2f[0x00/4];
    snprintf(buf, sizeof(buf), "h2f[0x00]=0x%08x\n", v0);
    msg(buf);

    munmap((void*)h2f, 0x1000);
    close(fd);
    msg("ALL OK\n");
    return 0;
}
