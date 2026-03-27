/*
 * enable_bridges.c — Enable Cyclone V HPS ↔ FPGA bridges via /dev/mem
 *
 * Clears reset bits in the Reset Manager brgmodrst register (0xFFD0501C)
 * and sets the L3 remap bits to make the h2f bridge visible.
 *
 * Build:  gcc -O2 -o enable_bridges enable_bridges.c
 * Usage:  ./enable_bridges
 */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>

#define RSTMGR_BASE     0xFFD05000
#define RSTMGR_SPAN     0x100
#define BRGMODRST_OFF   0x1C   /* Bridge Module Reset register */

#define SYSMGR_BASE     0xFFD08000
#define SYSMGR_SPAN     0x100
#define FPGAINTF_OFF    0x28   /* fpgaintfgrp_module register  */

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    /* --- Reset Manager: deassert bridge resets ---------------------- */
    volatile uint32_t *rstmgr = mmap(NULL, RSTMGR_SPAN,
                                     PROT_READ | PROT_WRITE, MAP_SHARED,
                                     fd, RSTMGR_BASE);
    if (rstmgr == MAP_FAILED) { perror("mmap rstmgr"); return 1; }

    volatile uint32_t *brgmodrst = (volatile uint32_t *)((char *)rstmgr + BRGMODRST_OFF);
    uint32_t old = *brgmodrst;
    *brgmodrst = 0;          /* clear all bridge reset bits */
    printf("brgmodrst: 0x%08x -> 0x%08x\n", old, *brgmodrst);
    munmap((void *)rstmgr, RSTMGR_SPAN);

    /* --- System Manager: enable FPGA interfaces --------------------- */
    volatile uint32_t *sysmgr = mmap(NULL, SYSMGR_SPAN,
                                     PROT_READ | PROT_WRITE, MAP_SHARED,
                                     fd, SYSMGR_BASE);
    if (sysmgr == MAP_FAILED) { perror("mmap sysmgr"); return 1; }

    volatile uint32_t *fpgaintf = (volatile uint32_t *)((char *)sysmgr + FPGAINTF_OFF);
    old = *fpgaintf;
    *fpgaintf = old | 0x7;   /* enable h2f, lwhps2fpga, fpga2hps interfaces */
    printf("fpgaintf:  0x%08x -> 0x%08x\n", old, *fpgaintf);
    munmap((void *)sysmgr, SYSMGR_SPAN);

    close(fd);
    printf("Bridges enabled.\n");
    return 0;
}
