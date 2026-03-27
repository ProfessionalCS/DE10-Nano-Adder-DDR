#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# run_trace.sh — On-board helper: replay a trace then spot-check addresses.
#
# Must be run ON the board as root from /root/deploy.
#
# Usage:
#   bash run_trace.sh                          — replay default trace, no verify
#   bash run_trace.sh replay                   — same as above
#   bash run_trace.sh verify                   — verify all stored addresses
#   bash run_trace.sh verify 0x7fff10a1f768    — verify one address
#   bash run_trace.sh verify all               — verify every stored address
#   bash run_trace.sh full                     — replay + verify all
#   bash run_trace.sh full 0x7fff10a1f768      — replay + verify one address
#
# Options (set before calling or export first):
#   TRACE=<file>       trace .bin file (default: dgemm3_lsq88.bin)
#   DELAY=<ms>         inter-op delay in ms for replay (default: 10)
# ═══════════════════════════════════════════════════════════════════════════
set -e
DEPLOY=/root/deploy
cd "$DEPLOY"

TRACE="${TRACE:-dgemm3_lsq88.bin}"
DELAY="${DELAY:-10}"
CMD="${1:-replay}"

# ── Helpers ──────────────────────────────────────────────────────────────
check_binaries() {
    [ -x ./mem_test ]    || { echo "ABORT: mem_test not found. Run: bash board_setup.sh"; exit 1; }
    [ -x ./manual_test ] || { echo "ABORT: manual_test not found. Run: bash board_setup.sh"; exit 1; }
    [ -f "./$TRACE" ]    || { echo "ABORT: trace file '$TRACE' not found in $DEPLOY"; exit 1; }
}

do_replay() {
    echo "═══════════════════════════════════════════"
    echo "  Replaying trace: $TRACE  (delay=${DELAY}ms)"
    echo "═══════════════════════════════════════════"
    ./mem_test trace "$TRACE" "$DELAY"
    echo ""
    echo "Trace replay done."
}

do_verify() {
    local addr="${1:-}"
    echo "═══════════════════════════════════════════"
    echo "  Verifying trace: $TRACE"
    [ -n "$addr" ] && echo "  Target: $addr" || echo "  Target: show stats only"
    echo "═══════════════════════════════════════════"
    if [ -z "$addr" ]; then
        ./manual_test verify "$TRACE"
    else
        ./manual_test verify "$TRACE" "$addr"
    fi
}

# ── Dispatch ─────────────────────────────────────────────────────────────
check_binaries

case "$CMD" in
    replay)
        do_replay
        ;;

    verify)
        do_verify "${2:-}"
        ;;

    full)
        do_replay
        echo ""
        do_verify "${2:-all}"
        ;;

    help|--help|-h)
        sed -n '3,18p' "$0"   # print the usage block at top of this file
        ;;

    *)
        echo "Unknown command: $CMD"
        echo "Usage: bash run_trace.sh [replay|verify|full|help] [addr|all]"
        exit 1
        ;;
esac
