#!/bin/bash
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
# deploy_to_board.sh â€” Full DE10-Nano deployment (DTB + RBF + auto-bridge)
#
# Run from WSL Ubuntu on the host PC (inside MemorySystem/).
#
# What this does:
#   1. Uploads RBF, all HPS source files, trace file
#   2. Compiles all HPS programs on-board
#   3. Patches DTB (enables bridge nodes) + installs RBF on boot FAT
#   4. Installs a systemd service so fix_bridges runs automatically at boot
#   5. Reboots, waits, verifies FPGA + bridges + smoke test
#
# After this script succeeds the board will auto-fix bridges on every boot.
#
# Prerequisites: sshpass is optional; without it the script falls back to
# interactive ssh/scp password prompts.
# Usage:  bash deploy_to_board.sh
# â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
set -e

BOARD_IP="${BOARD_IP:-192.168.0.2}"
BOARD_USER="${BOARD_USER:-root}"
BOARD_PASS="${BOARD_PASS:-root}"
SSH_OPTS="-o StrictHostKeyChecking=no"
if command -v sshpass > /dev/null 2>&1; then
    SSH="sshpass -p $BOARD_PASS ssh $SSH_OPTS $BOARD_USER@$BOARD_IP"
    SCP="sshpass -p $BOARD_PASS scp $SSH_OPTS"
else
    SSH="ssh $SSH_OPTS $BOARD_USER@$BOARD_IP"
    SCP="scp $SSH_OPTS"
    echo "INFO: sshpass not found; using interactive ssh/scp password prompts."
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HPS_DIR="$SCRIPT_DIR/transfer_quatus/software/hps_mem_test"
RBF="$SCRIPT_DIR/transfer_quatus/output_files/soc_system.rbf"
TRACE="$SCRIPT_DIR/mem-traces-v2/traces/dgemm3_lsq88.bin"

echo "â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—"
echo "â•‘  DE10-Nano Full Deployment                       â•‘"
echo "â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"

# â”€â”€ Step 0: Pre-flight checks â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 0] Pre-flight checks ..."
FAIL=0
for f in "$RBF" "$HPS_DIR/mem_test.c" "$HPS_DIR/manual_test.c" \
         "$HPS_DIR/enable_bridges.c" "$HPS_DIR/fix_bridges.c"; do
    if [ -f "$f" ]; then echo "  OK: $(basename "$f")"
    else echo "  MISSING: $f"; FAIL=1; fi
done
[ "$FAIL" -eq 0 ] || { echo "ABORT: missing required files."; exit 1; }

echo ""
echo "  Pinging board at $BOARD_IP ..."
for i in 1 2 3; do
    ping -c 1 -W 3 "$BOARD_IP" > /dev/null 2>&1 && break
    [ "$i" -eq 3 ] && { echo "FAIL: board not reachable at $BOARD_IP"; exit 1; }
    sleep 2
done
echo "  Board is reachable."

# â”€â”€ Step 1: Upload files â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 1] Uploading files to board ..."
$SSH "mkdir -p /root/deploy"

$SCP "$RBF" "$BOARD_USER@$BOARD_IP:/root/deploy/soc_system.rbf"
echo "  soc_system.rbf"

for f in mem_test.c manual_test.c fpga_manual.c enable_bridges.c fix_bridges.c \
         test_h2f.c devmem2.c board_setup.sh; do
    [ -f "$HPS_DIR/$f" ] && $SCP "$HPS_DIR/$f" "$BOARD_USER@$BOARD_IP:/root/deploy/"
done
echo "  HPS source files + board_setup.sh"

[ -f "$TRACE" ] && $SCP "$TRACE" "$BOARD_USER@$BOARD_IP:/root/deploy/" && echo "  trace file"

# â”€â”€ Step 2: Compile on board â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 2] Compiling on board ..."
$SSH 'cd /root/deploy &&
  gcc -O2 -o mem_test mem_test.c &&
  gcc -O2 -o manual_test manual_test.c &&
  gcc -O2 -o fpga_manual fpga_manual.c 2>/dev/null || true &&
  gcc -O2 -o enable_bridges enable_bridges.c &&
  gcc -O2 -o fix_bridges fix_bridges.c &&
  gcc -O2 -o test_h2f test_h2f.c 2>/dev/null || true &&
  gcc -O2 -o devmem2 devmem2.c 2>/dev/null || true &&
  cp devmem2 /usr/local/bin/devmem2 2>/dev/null || true &&
  echo BUILD_OK'

# â”€â”€ Step 3: Fix DTB + install RBF on boot partition â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 3] Patching DTB + installing RBF ..."
$SSH 'bash -s' << 'REMOTE_BOOT'
set -e
mkdir -p /mnt/bootfat
umount /mnt/bootfat 2>/dev/null || true
mount /dev/mmcblk0p1 /mnt/bootfat

DTB=/mnt/bootfat/socfpga_cyclone5_de0_nano_soc.dtb
[ -f "$DTB" ] || { echo "FAIL: DTB not found"; umount /mnt/bootfat; exit 1; }

# Keep original backup (only first time ever)
[ -f "${DTB}.orig" ] || cp "$DTB" "${DTB}.orig"

# Decompile â†’ fix â†’ recompile
dtc -I dtb -O dts -o /tmp/_deploy.dts "$DTB" 2>/dev/null
sed -i 's/status = "disabled"/status = "okay"/g' /tmp/_deploy.dts

awk '
/fpga-bridge@ff400000|fpga-bridge@ff500000|fpga-bridge@ff600000|fpga2sdram/ {
    in_bridge=1
}
{
    print
    if (in_bridge && /status = "okay"/) {
        print "\t\t\tbridge-enable = <1>;"
        in_bridge=0
    }
}
' /tmp/_deploy.dts > /tmp/_deploy_fixed.dts

dtc -I dts -O dtb -o /tmp/_deploy.dtb /tmp/_deploy_fixed.dts 2>/dev/null
cp /tmp/_deploy.dtb "$DTB"
echo "  DTB patched (bridges enabled)"

# Install RBF
cp /root/deploy/soc_system.rbf /mnt/bootfat/soc_system.rbf
echo "  RBF installed"

sync
umount /mnt/bootfat
rm -f /tmp/_deploy.dts /tmp/_deploy_fixed.dts /tmp/_deploy.dtb
echo "  Boot partition synced + unmounted"
REMOTE_BOOT

# â”€â”€ Step 4: Install systemd auto-bridge service â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 4] Installing auto-bridge-fix service ..."
$SSH 'bash -s' << 'REMOTE_SVC'
set -e

# Create the bridge-fix boot script
cat > /root/deploy/fix_bridges_boot.sh << 'SCRIPT'
#!/bin/bash
# Runs at boot via systemd to enable FPGA bridges.
# The kernel bridge driver does not honor bridge-enable in the DTB
# on this board, so we poke the registers directly.
LOG=/root/deploy/bridge_boot.log
echo "$(date): fix_bridges_boot.sh starting" > "$LOG"
/root/deploy/fix_bridges >> "$LOG" 2>&1
RET=$?
echo "$(date): fix_bridges exited $RET" >> "$LOG"
exit $RET
SCRIPT
chmod +x /root/deploy/fix_bridges_boot.sh

# Create + enable systemd service
cat > /etc/systemd/system/fpga-bridges.service << 'SVC'
[Unit]
Description=Enable FPGA bridges via /dev/mem register writes
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/root/deploy/fix_bridges_boot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable fpga-bridges.service 2>/dev/null
echo "  fpga-bridges.service installed + enabled"
REMOTE_SVC

# â”€â”€ Step 5: Reboot â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 5] Rebooting ..."
$SSH "sync; reboot" 2>/dev/null || true
echo "  Reboot sent. Waiting for board ..."

sleep 30
for i in $(seq 1 20); do
    if ping -c 1 -W 2 "$BOARD_IP" > /dev/null 2>&1; then
        echo "  Board up after ~$((30 + i*5))s"
        break
    fi
    [ "$i" -eq 20 ] && { echo "FAIL: board did not come back (130s timeout)"; exit 1; }
    sleep 5
done
sleep 5   # let SSH daemon start

# â”€â”€ Step 6: Post-boot verification â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 6] Verifying ..."

FPGA=$($SSH "cat /sys/class/fpga_manager/fpga0/state 2>/dev/null" || echo "UNKNOWN")
echo "  FPGA state: $FPGA"

SVC_OK=$($SSH "systemctl is-active fpga-bridges.service 2>/dev/null" || echo "inactive")
echo "  Bridge service: $SVC_OK"

# Show bridge log
$SSH "cat /root/deploy/bridge_boot.log 2>/dev/null" || true

# Verify H2F is accessible â€” if not, run fix_bridges one more time
if ! $SSH "cd /root/deploy && ./test_h2f 2>&1" > /dev/null 2>&1; then
    echo "  H2F not ready yet â€” running fix_bridges ..."
    $SSH "cd /root/deploy && ./fix_bridges 2>&1"
fi

echo ""
echo "  Bridge states:"
for br in br0 br1 br2 br3; do
    STATE=$($SSH "cat /sys/class/fpga_bridge/$br/state 2>/dev/null" || echo "MISSING")
    echo "    $br: $STATE"
done

# â”€â”€ Step 7: Smoke test â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo ""
echo "[Step 7] Smoke test ..."
$SSH "cd /root/deploy && ./mem_test smoke 2>&1"

echo ""
echo "â•”â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•—"
echo "â•‘  DEPLOYMENT COMPLETE                             â•‘"
echo "â•šâ•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•"
echo ""
echo "Board is live at $BOARD_IP.  Quick commands:"
echo "  make board-smoke      # smoke test"
echo "  make board-status     # FPGA + bridges + status"
echo "  make board-test       # manual_test correctness suite"
echo "  make board-trace      # replay trace file"
