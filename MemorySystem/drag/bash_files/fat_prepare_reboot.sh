#!/bin/bash
# Run on the board after the staged payload has been copied into /root/deploy.
# Mirrors the recovery flow up to the reboot boundary:
#   1. compile the board-side tools
#   2. install the fpga-bridges systemd service
#   3. install the DTB/RBF onto the boot FAT partition
#   4. stop and tell the user to reboot

set -e

DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy}"
BOOTFAT_MNT="${BOOTFAT_MNT:-/mnt/bootfat}"

cd "$DEPLOY_DIR"

echo "===================================================="
echo " Board Recovery Prep (stops before reboot)"
echo "===================================================="

compile_if() {
    local src="$1"
    local bin="$2"
    local flags="${3:-}"

    if [ -f "$src" ]; then
        if gcc -O2 $flags -o "$bin" "$src"; then
            echo "  built: $bin"
        else
            echo "  WARN: failed to compile $src"
        fi
    else
        echo "  skip: $src not found"
    fi
}

echo ""
echo "[1] Compiling board-side tools ..."
compile_if mem_test.c mem_test
compile_if manual_test.c manual_test
compile_if fpga_manual.c fpga_manual
compile_if enable_bridges.c enable_bridges
compile_if fix_bridges.c fix_bridges
compile_if test_h2f.c test_h2f
compile_if devmem2.c devmem2
compile_if tlb_evict.c tlb_evict
compile_if ddr3_test.c ddr3_test
compile_if devmem_verify.c devmem_verify
compile_if stress_test.c stress_test
compile_if setup_fpga.c setup_fpga
compile_if test_bridge.c test_bridge
compile_if test_bridge2.c test_bridge2

[ -f devmem2 ] && cp devmem2 /usr/local/bin/devmem2 2>/dev/null || true
chmod +x "$DEPLOY_DIR"/*.sh 2>/dev/null || true

[ -f fix_bridges ] || { echo "ABORT: fix_bridges binary missing."; exit 1; }

echo ""
echo "[2] Installing fpga-bridges.service ..."
cat > "$DEPLOY_DIR/fix_bridges_boot.sh" <<'SCRIPT'
#!/bin/bash
LOG=/root/deploy/bridge_boot.log
echo "$(date): fix_bridges_boot starting" > "$LOG"
/root/deploy/fix_bridges >> "$LOG" 2>&1
RET=$?
echo "$(date): fix_bridges exited $RET" >> "$LOG"
exit $RET
SCRIPT
chmod +x "$DEPLOY_DIR/fix_bridges_boot.sh"

cat > /etc/systemd/system/fpga-bridges.service <<'SVC'
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
systemctl enable fpga-bridges.service 2>/dev/null || true
echo "  fpga-bridges.service installed"

echo ""
echo "[3] Installing DTB + RBF onto boot FAT ..."

RBF_SRC="$DEPLOY_DIR/soc_system.rbf"
DTB_SRC="$DEPLOY_DIR/good.dtb"
DTB_DST="$BOOTFAT_MNT/socfpga_cyclone5_de0_nano_soc.dtb"
MOUNTED_HERE=0

[ -f "$RBF_SRC" ] || { echo "ABORT: $RBF_SRC not found."; exit 1; }

mkdir -p "$BOOTFAT_MNT"
if mountpoint -q "$BOOTFAT_MNT" 2>/dev/null; then
    echo "  using existing mount at $BOOTFAT_MNT"
else
    mount /dev/mmcblk0p1 "$BOOTFAT_MNT"
    MOUNTED_HERE=1
    echo "  mounted /dev/mmcblk0p1 at $BOOTFAT_MNT"
fi

if [ -f "$DTB_DST" ]; then
    [ -f "${DTB_DST}.orig" ] || cp "$DTB_DST" "${DTB_DST}.orig"

    if [ -f "$DTB_SRC" ]; then
        cp "$DTB_SRC" "$DTB_DST"
        echo "  installed pre-patched DTB"
    elif command -v dtc > /dev/null 2>&1; then
        dtc -I dtb -O dts -o /tmp/_prep.dts "$DTB_DST" 2>/dev/null
        sed -i 's/status = "disabled"/status = "okay"/g' /tmp/_prep.dts
        awk '
/fpga-bridge@ff400000|fpga-bridge@ff500000|fpga-bridge@ff600000|fpga2sdram/ { in_bridge=1 }
{
    print
    if (in_bridge && /status = "okay"/) { print "\t\t\tbridge-enable = <1>;"; in_bridge=0 }
}
' /tmp/_prep.dts > /tmp/_prep_fixed.dts
        dtc -I dts -O dtb -o /tmp/_prep.dtb /tmp/_prep_fixed.dts 2>/dev/null
        cp /tmp/_prep.dtb "$DTB_DST"
        rm -f /tmp/_prep.dts /tmp/_prep_fixed.dts /tmp/_prep.dtb
        echo "  patched DTB on-board"
    else
        echo "  WARN: no good.dtb and no dtc; leaving existing DTB in place"
    fi
else
    echo "  WARN: boot DTB missing at $DTB_DST"
fi

cp "$RBF_SRC" "$BOOTFAT_MNT/soc_system.rbf"
echo "  installed soc_system.rbf"
sync
if [ "$MOUNTED_HERE" -eq 1 ]; then
    umount "$BOOTFAT_MNT"
    echo "  boot FAT synced and unmounted"
else
    echo "  boot FAT synced (left mounted at $BOOTFAT_MNT)"
fi

echo ""
echo "Preparation complete. Reboot is required."
echo ""
echo "Run now:"
echo "  sync"
echo "  reboot"
echo ""
echo "After the board comes back:"
echo "  cd /root/deploy"
echo "  make post-reboot"
echo ""
echo "Then continue with:"
echo "  make smoke"
echo "  make test"
