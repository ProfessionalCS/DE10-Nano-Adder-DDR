/*
 * devmem2 — read/write physical memory via /dev/mem
 *
 * Usage:
 *   devmem2 ADDRESS [b|h|w|q] [VALUE]
 *
 *   ADDRESS  physical address (hex, must start with 0x)
 *   b=8-bit, h=16-bit, w=32-bit (default), q=64-bit
 *   VALUE    if provided, write this value; otherwise read
 *
 * Examples — DE10-Nano H2F bridge base 0xC0000000:
 *   devmem2 0xC0000000        # read 32-bit status[31:0]
 *   devmem2 0xC0000004        # read status[63:32]
 *   devmem2 0xC0000008 w 0x1  # write adder_b (triggers op)
 *   devmem2 0xC0000010 w 0x2  # write adder_a
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <ctype.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define PAGE_SIZE  4096UL
#define PAGE_MASK  (~(PAGE_SIZE - 1))

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s ADDRESS [b|h|w|q] [VALUE]\n"
        "  ADDRESS  physical address (0x...)\n"
        "  b=8-bit  h=16-bit  w=32-bit (default)  q=64-bit\n"
        "  VALUE    write this value (omit to read)\n",
        prog);
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(argv[0]); return 1; }

    off_t target = (off_t)strtoul(argv[1], NULL, 0);
    int   width  = 'w';
    int   do_write = 0;
    uint64_t writeval = 0;

    if (argc >= 3) width    = tolower((unsigned char)argv[2][0]);
    if (argc >= 4) { writeval = strtoull(argv[3], NULL, 0); do_write = 1; }

    if (width != 'b' && width != 'h' && width != 'w' && width != 'q') {
        fprintf(stderr, "Unknown width '%c' — use b/h/w/q\n", width);
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    /* Map a single page containing the target address */
    off_t map_base_off = target & PAGE_MASK;
    void *map = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE,
                     MAP_SHARED, fd, map_base_off);
    if (map == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    volatile void *vaddr = (char *)map + (target - map_base_off);

    if (do_write) {
        switch (width) {
        case 'b': *(volatile uint8_t  *)vaddr = (uint8_t) writeval; break;
        case 'h': *(volatile uint16_t *)vaddr = (uint16_t)writeval; break;
        case 'w': *(volatile uint32_t *)vaddr = (uint32_t)writeval; break;
        case 'q': *(volatile uint64_t *)vaddr = (uint64_t)writeval; break;
        }
        printf("Written 0x%llX to 0x%lX\n",
               (unsigned long long)writeval, (unsigned long)target);
    } else {
        uint64_t val = 0;
        int nibbles;
        switch (width) {
        case 'b': val = *(volatile uint8_t  *)vaddr; nibbles =  2; break;
        case 'h': val = *(volatile uint16_t *)vaddr; nibbles =  4; break;
        default:
        case 'w': val = *(volatile uint32_t *)vaddr; nibbles =  8; break;
        case 'q': val = *(volatile uint64_t *)vaddr; nibbles = 16; break;
        }
        printf("0x%0*llX\n", nibbles, (unsigned long long)val);
    }

    munmap(map, PAGE_SIZE);
    close(fd);
    return 0;
}
