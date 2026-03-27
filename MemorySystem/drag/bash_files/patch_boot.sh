#!/bin/bash
# Run on the DE10-Nano board: patches DTB and installs new RBF onto the FAT boot partition
set -e

mkdir -p /mnt/bootfat
umount /mnt/bootfat 2>/dev/null || true
mount /dev/mmcblk0p1 /mnt/bootfat

DTB=/mnt/bootfat/socfpga_cyclone5_de0_nano_soc.dtb
test -f "$DTB" || { echo "FAIL: DTB not found on boot partition"; umount /mnt/bootfat; exit 1; }
test -f "${DTB}.orig" || cp "$DTB" "${DTB}.orig"

dtc -I dtb -O dts -o /tmp/_d.dts "$DTB" 2>/dev/null
sed -i 's/status = \"disabled\"/status = \"okay\"/g' /tmp/_d.dts
dtc -I dts -O dtb -o /tmp/_d.dtb /tmp/_d.dts 2>/dev/null
cp /tmp/_d.dtb "$DTB"
echo "  DTB patched"

cp /root/deploy/soc_system.rbf /mnt/bootfat/soc_system.rbf
echo "  RBF installed ($(du -sh /mnt/bootfat/soc_system.rbf | cut -f1))"

sync
umount /mnt/bootfat
rm -f /tmp/_d.dts /tmp/_d.dtb
echo "  Boot partition updated and unmounted"
