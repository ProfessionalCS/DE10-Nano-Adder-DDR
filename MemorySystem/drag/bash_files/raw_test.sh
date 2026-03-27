#!/bin/bash
set -e

echo "=== Direct FPGA register poke ==="

cd /root/deploy

# Quick C program inline
cat > /tmp/raw_test.c << 'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    volatile uint32_t *p = mmap(NULL, 0x1000, PROT_READ|PROT_WRITE,
                                MAP_SHARED, fd, 0xC0000000);

    printf("Read  [0x00] = 0x%08X\n", p[0]);
    printf("Read  [0x04] = 0x%08X\n", p[1]);
    printf("Read  [0x08] = 0x%08X\n", p[2]);
    printf("Read  [0x0C] = 0x%08X\n", p[3]);
    printf("Read  [0x10] = 0x%08X\n", p[4]);

    printf("\nWrite 0xDEADBEEF to [0x10]\n");
    p[4] = 0xDEADBEEF;
    asm volatile("dsb sy":::"memory");
    usleep(1000);

    printf("Read  [0x00] = 0x%08X\n", p[0]);
    printf("Read  [0x04] = 0x%08X\n", p[1]);
    printf("Read  [0x10] = 0x%08X\n", p[4]);

    printf("\nWrite 0x12345678 to [0x08]\n");
    p[2] = 0x12345678;
    asm volatile("dsb sy":::"memory");
    usleep(1000);

    printf("Read  [0x00] = 0x%08X\n", p[0]);
    printf("Read  [0x04] = 0x%08X\n", p[1]);

    /* Try reading at an offset way past the PIOs to see if we get different data */
    printf("\nFar offset reads:\n");
    printf("  [0x100] = 0x%08X\n", p[0x100/4]);
    printf("  [0x200] = 0x%08X\n", p[0x200/4]);
    printf("  [0x400] = 0x%08X\n", p[0x400/4]);

    munmap((void*)p, 0x1000);
    close(fd);
    return 0;
}
CEOF

gcc -O2 -o /tmp/raw_test /tmp/raw_test.c
/tmp/raw_test
