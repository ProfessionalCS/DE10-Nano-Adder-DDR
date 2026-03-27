#!/bin/bash
set -e

echo "=== Fix boot order: remove extlinux so U-Boot uses boot.scr ==="

# Mount boot partition
mount /dev/mmcblk0p1 /mnt 2>/dev/null || true

# Back up extlinux
cp -r /mnt/extlinux /mnt/extlinux.bak 2>/dev/null || true

# Remove extlinux so U-Boot falls through to boot.scr
rm -rf /mnt/extlinux
echo "Removed /mnt/extlinux"

# Verify boot.scr is present
ls -la /mnt/boot.scr /mnt/u-boot.scr /mnt/soc_system.rbf
echo "Boot files verified."

sync
umount /mnt
echo "Done. Reboot to test."
