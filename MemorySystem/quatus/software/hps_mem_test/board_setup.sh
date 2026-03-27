#!/bin/bash
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# board_setup.sh â€” Runs ON the DE10-Nano to (re)initialize everything.
#
# Handles:
#   1. Compile all programs from source (if .c files are present)
#   2. Install systemd fpga-bridges.service (auto-fix bridges at boot)
#   3. Patch DTB + install RBF onto boot FAT (/dev/mmcblk0p1)
#   4. Enable FPGA bridges NOW (via fix_bridges, no reboot needed)
#   5. Run smoke test + manual_test suite
#
# Usage (on board):
#   cd /root/deploy && bash board_setup.sh
#
# Usage (from host WSL):
#   sshpass -p root ssh root@192.168.0.2 "cd /root/deploy && bash board_setup.sh"
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

set -e
DEPLOY=/root/deploy
cd "$DEPLOY"

echo "â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—"
echo "â•‘  DE10-Nano Board Setup (running on-board)        â•‘"
echo "â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"

# â”€â”€ Step 1: Compile programs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[1] Compiling programs ..."
BUILT=0 SKIPPED=0

compile_if() {
    local src="$1" bin="$2" flags="${3:-}"
    if [ -f "$src" ]; then
        gcc -O2 $flags -o "$bin" "$src" && echo "  OK: $bin" && BUILT=$((BUILT+1)) \
            || echo "  WARN: $src failed to compile (skipping)"
    else
        echo "  SKIP: $src not found"
        SKIPPED=$((SKIPPED+1))
    fi
}

compile_if mem_test.c      mem_test
compile_if manual_test.c   manual_test
compile_if fpga_manual.c   fpga_manual
compile_if fix_bridges.c   fix_bridges
compile_if enable_bridges.c enable_bridges
compile_if test_h2f.c      test_h2f
compile_if devmem2.c       devmem2
compile_if tlb_evict.c     tlb_evict
compile_if true_stress_test.c true_stress_test

# Put devmem2 on PATH if compiled
[ -f devmem2 ] && cp devmem2 /usr/local/bin/devmem2 2>/dev/null || true

# Make shell scripts executable
chmod +x /root/deploy/*.sh 2>/dev/null || true

echo "  Compiled $BUILT, skipped $SKIPPED"

# Require fix_bridges at minimum
[ -f fix_bridges ] || { echo "ABORT: fix_bridges binary missing and could not be built."; exit 1; }

# â”€â”€ Step 2: Install systemd auto-bridge service â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[2] Installing fpga-bridges.service ..."

cat > /root/deploy/fix_bridges_boot.sh << 'SCRIPT'
#!/bin/bash
# Runs at boot via systemd to enable FPGA bridges.
# The kernel bridge driver does not reliably honor bridge-enable in the DTB,
# so we write the registers directly via /dev/mem.
LOG=/root/deploy/bridge_boot.log
echo "$(date): fix_bridges_boot starting" > "$LOG"
/root/deploy/fix_bridges >> "$LOG" 2>&1
RET=$?
echo "$(date): fix_bridges exited $RET" >> "$LOG"
exit $RET
SCRIPT
chmod +x /root/deploy/fix_bridges_boot.sh

cat > /etc/systemd/system/fpga-bridges.service << 'SVC'
[Unit]
Description=Enable FPGA bridges via /dev/mem register writes
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/root/deploy/fix_bridges_boot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable fpga-bridges.service 2>/dev/null && echo "  fpga-bridges.service enabled (will run on next boot)"

# â”€â”€ Step 3: Install RBF + patch DTB (if RBF present) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[3] Boot partition (DTB + RBF) ..."

_boot_partition_setup() {
    if [ ! -f /root/deploy/soc_system.rbf ]; then
        echo "  SKIP: soc_system.rbf not found (upload with deploy-quick to update)"
        return 0
    fi

    mkdir -p /mnt/bootfat
    umount /mnt/bootfat 2>/dev/null || true
    mount /dev/mmcblk0p1 /mnt/bootfat || { echo "  WARN: could not mount boot FAT â€” skipping"; return 0; }

    DTB=/mnt/bootfat/socfpga_cyclone5_de0_nano_soc.dtb
    if [ ! -f "$DTB" ]; then
        echo "  WARN: DTB not found on boot partition â€” skipping patch"
    else
        # Backup original DTB exactly once
        [ -f "${DTB}.orig" ] || { cp "$DTB" "${DTB}.orig"; echo "  Backed up original DTB"; }

        # Patch DTB: disabled â†’ okay + bridge-enable (skip if dtc unavailable or already patched)
        if command -v dtc > /dev/null 2>&1; then
            dtc -I dtb -O dts -o /tmp/_setup.dts "$DTB" 2>/dev/null || { echo "  WARN: dtc decompile failed â€” skipping DTB patch"; umount /mnt/bootfat; return 0; }
            sed -i 's/status = "disabled"/status = "okay"/g' /tmp/_setup.dts
            awk '
/fpga-bridge@ff400000|fpga-bridge@ff500000|fpga-bridge@ff600000|fpga2sdram/ { in_bridge=1 }
{
    print
    if (in_bridge && /status = "okay"/) { print "\t\t\tbridge-enable = <1>;"; in_bridge=0 }
}
' /tmp/_setup.dts > /tmp/_setup_fixed.dts
            if dtc -I dts -O dtb -o /tmp/_setup.dtb /tmp/_setup_fixed.dts 2>/dev/null; then
                cp /tmp/_setup.dtb "$DTB"
                echo "  DTB patched (bridges enabled)"
            else
                echo "  WARN: dtc recompile failed â€” keeping existing DTB"
            fi
            rm -f /tmp/_setup.dts /tmp/_setup_fixed.dts /tmp/_setup.dtb
        else
            echo "  INFO: dtc not available â€” DTB not patched (fix_bridges handles bridges)"
        fi
    fi

    # Install RBF
    cp /root/deploy/soc_system.rbf /mnt/bootfat/soc_system.rbf
    echo "  RBF installed"
    sync
    umount /mnt/bootfat
    echo "  Boot partition synced + unmounted"
}

_boot_partition_setup || echo "  WARN: boot partition step had errors (non-fatal)"

# â”€â”€ Step 4: Enable bridges RIGHT NOW â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[4] Enabling FPGA bridges (fix_bridges) ..."
/root/deploy/fix_bridges

# â”€â”€ Step 5: Show status â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[5] Hardware status ..."
echo "  FPGA:    $(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo UNKNOWN)"
for br in br0 br1 br2 br3; do
    echo "  $br:     $(cat /sys/class/fpga_bridge/$br/state 2>/dev/null || echo MISSING)"
done
echo "  Service: $(systemctl is-active fpga-bridges.service 2>/dev/null || echo not-installed)"

# â”€â”€ Step 6: Smoke test (quick sanity) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[6] Smoke test ..."
if [ ! -f /root/deploy/mem_test ]; then
    echo "  SKIP: mem_test not compiled"
else
    /root/deploy/mem_test smoke
fi

# â”€â”€ Step 7: Full correctness test â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[7] Correctness test (manual_test clean test) ..."
if [ ! -f /root/deploy/manual_test ]; then
    echo "  SKIP: manual_test not compiled"
else
    /root/deploy/manual_test clean test
fi

echo ""
echo "â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—"
echo "â•‘  BOARD SETUP COMPLETE                            â•‘"
echo "â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
echo ""
echo "Bridges are enabled.  Service will auto-fix on next reboot."
echo "To re-run at any time:  cd /root/deploy && bash board_setup.sh"
