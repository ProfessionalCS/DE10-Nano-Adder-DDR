#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <signal.h>

void handler(int sig) { printf("SIGNAL %d\n", sig); _exit(1); }

int main() {
    signal(SIGBUS, handler);
    signal(SIGSEGV, handler);
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open"); return 1; }

    /* Read brgmodrst to verify bridges are enabled */
    volatile uint32_t *rst = mmap(NULL, 0x100, PROT_READ, MAP_SHARED, fd, 0xFFD05000);
    if (rst == MAP_FAILED) { perror("mmap rst"); return 1; }
    printf("brgmodrst = 0x%08x\n", rst[0x1C/4]);
    munmap((void*)rst, 0x100);

    /* Read sysmgr fpgaintf */
    volatile uint32_t *sys = mmap(NULL, 0x100, PROT_READ, MAP_SHARED, fd, 0xFFD08000);
    if (sys == MAP_FAILED) { perror("mmap sys"); return 1; }
    printf("fpgaintf  = 0x%08x\n", sys[0x28/4]);
    munmap((void*)sys, 0x100);

    /* Try h2f bridge at 0xC0000000 */
    printf("Mapping 0xC0000000...\n");
    volatile uint32_t *h2f = mmap(NULL, 0x1000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xC0000000);
    if (h2f == MAP_FAILED) { perror("mmap h2f"); return 1; }
    printf("mmap OK, attempting 32-bit read at offset 0...\n");
    uint32_t val = h2f[0];
    printf("h2f[0] = 0x%08x\n", val);
    printf("h2f[1] = 0x%08x\n", h2f[1]);
    printf("h2f[2] = 0x%08x\n", h2f[2]);
    printf("h2f[3] = 0x%08x\n", h2f[3]);
    printf("h2f[4] = 0x%08x\n", h2f[4]);
    munmap((void*)h2f, 0x1000);
    close(fd);
    printf("All reads OK\n");
    return 0;
}
