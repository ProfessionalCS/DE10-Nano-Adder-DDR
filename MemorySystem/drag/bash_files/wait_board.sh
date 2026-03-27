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

$SSH "sync; reboot" 2>/dev/null || true
echo "Reboot sent. Waiting 35s..."
sleep 35
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    ping -c 1 -W 2 "$BOARD_IP" > /dev/null 2>&1 && echo "Board is back after ~$((35 + i*5))s" && exit 0
    echo "  Still waiting... ($i)"
    sleep 5
done
echo "TIMEOUT: board did not come back"
exit 1
