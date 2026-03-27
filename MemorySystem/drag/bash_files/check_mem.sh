#!/bin/bash
set -e

BOARD_IP="${BOARD_IP:-192.168.0.2}"
BOARD_USER="${BOARD_USER:-root}"
BOARD_PASS="${BOARD_PASS:-root}"

if command -v sshpass > /dev/null 2>&1; then
    SSH="sshpass -p $BOARD_PASS ssh -o StrictHostKeyChecking=no $BOARD_USER@$BOARD_IP"
else
    SSH="ssh -o StrictHostKeyChecking=no $BOARD_USER@$BOARD_IP"
fi

$SSH << 'EOF'
echo "=== /proc/iomem ==="
cat /proc/iomem
echo ""
echo "=== meminfo ==="
cat /proc/meminfo | head -5
echo ""
echo "=== cmdline ==="
cat /proc/cmdline
echo ""
echo "=== devmem2 test ==="
cd /root/deploy && ./devmem2 0x38001000 w
echo ""
echo "=== devmem2 low addr ==="
cd /root/deploy && ./devmem2 0x20000000 w
EOF
