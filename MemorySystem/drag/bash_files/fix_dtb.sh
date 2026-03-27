#!/bin/bash
set -e

# Decompile current DTB
mount /dev/mmcblk0p1 /mnt 2>/dev/null || true
dtc -I dtb -O dts -o /root/current.dts /mnt/socfpga_cyclone5_de0_nano_soc.dtb 2>/dev/null
echo "Decompiled DTB."

# Add firmware-name to base_fpga_region
awk '
/base_fpga_region \{/ { found=1 }
found && /compatible =/ {
    print
    print "\t\t\tfirmware-name = \"soc_system.rbf\";"
    found=0
    next
}
{ print }
' /root/current.dts > /root/modified.dts
echo "Added firmware-name."

# Verify
echo "--- base_fpga_region section ---"
grep -A10 base_fpga_region /root/modified.dts
echo "--- end ---"

# Recompile DTB
dtc -I dts -O dtb -o /root/new.dtb /root/modified.dts 2>/dev/null
echo "Compiled new DTB."

# Install
cp /root/new.dtb /mnt/socfpga_cyclone5_de0_nano_soc.dtb
sync
echo "Installed new DTB."

# Also make sure RBF is in /lib/firmware and on boot partition
cp /root/deploy/soc_system.rbf /lib/firmware/soc_system.rbf 2>/dev/null || true
echo "RBF in /lib/firmware."

umount /mnt 2>/dev/null || true
echo "Done. Reboot to apply."
