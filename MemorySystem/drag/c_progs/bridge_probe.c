#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <signal.h>
#include <setjmp.h>

static sigjmp_buf jmp;
static void bus_handler(int sig) { siglongjmp(jmp, 1); }

static void probe(const char *name, off_t phys, size_t span) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return; }

    volatile uint32_t *base = mmap(NULL, span, PROT_READ | PROT_WRITE,
                                    MAP_SHARED, fd, phys);
    if (base == MAP_FAILED) {
        printf("  %s: mmap FAILED at 0x%08lX\n", name, (unsigned long)phys);
        close(fd);
        return;
    }
    printf("  %s at 0x%08lX mapped ok\n", name, (unsigned long)phys);

    struct sigaction sa = { .sa_handler = bus_handler };
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);

    /* Try reading first 8 32-bit words */
    for (int i = 0; i < 8; i++) {
        if (sigsetjmp(jmp, 1) == 0) {
            uint32_t val = base[i];
            printf("    [0x%02X] = 0x%08X\n", i*4, val);
        } else {
            printf("    [0x%02X] = *** BUS ERROR ***\n", i*4);
            break;
        }
    }

    /* Try a write+readback at offset 0x20 (pio64_out_0 / adder_a) */
    if (sigsetjmp(jmp, 1) == 0) {
        base[0x20/4] = 0xCAFEBABE;  /* offset 0x20 */
        __asm__ __volatile__("dsb sy" ::: "memory");
        uint32_t rb = base[0x20/4];
        printf("    Write 0xCAFEBABE to [0x20], read back 0x%08X\n", rb);
    } else {
        printf("    Write test at [0x20]: *** BUS ERROR ***\n");
    }

    /* Also try 64-bit read at offset 0 (status register) */
    volatile uint64_t *base64 = (volatile uint64_t *)base;
    if (sigsetjmp(jmp, 1) == 0) {
        uint64_t val64 = base64[0];
        printf("    64-bit [0x00] = 0x%016llX\n", (unsigned long long)val64);
    } else {
        printf("    64-bit [0x00]: *** BUS ERROR ***\n");
    }

    signal(SIGBUS, SIG_DFL);
    signal(SIGSEGV, SIG_DFL);
    munmap((void*)base, span);
    close(fd);
}

int main(void) {
    printf("=== Bridge Probe (H2F only) ===\n");
    printf("H2F (full) bridge:\n");
    probe("h2f", 0xC0000000, 0x1000);
    printf("=== Done ===\n");
    return 0;
}
