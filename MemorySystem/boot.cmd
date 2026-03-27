echo "=== FPGA Boot Script ==="

# Load FPGA bitstream from FAT partition into RAM
fatload mmc 0:1 0x2000000 soc_system.rbf
echo "FPGA RBF loaded to RAM"

# Program the FPGA
fpga load 0 0x2000000 ${filesize}
echo "FPGA programmed"

# Enable HPS-to-FPGA bridges
bridge enable
echo "Bridges enabled"

# Load kernel and DTB
fatload mmc 0:1 ${kernel_addr_r} zImage
fatload mmc 0:1 ${fdt_addr_r} socfpga_cyclone5_de0_nano_soc.dtb

# Set boot args and boot
setenv bootargs root=/dev/mmcblk0p2 rw rootwait earlyprintk console=ttyS0,115200n8
echo "Booting Linux..."
bootz ${kernel_addr_r} - ${fdt_addr_r}
