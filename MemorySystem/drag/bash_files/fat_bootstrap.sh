#!/bin/bash
# Offline deploy entrypoint run directly from the mounted boot FAT partition.
#
# Expected layout on the FAT partition:
#   mem_autodeploy/
#     Makefile
#     fat_bootstrap.sh
#     payload/
#       soc_system.rbf
#       good.dtb              (optional)
#       hps_mem_test/
#       traces/
#
# This script copies the staged payload into /root/deploy and then runs a
# board-side recovery-prep flow that stops before reboot. After the reboot,
# the copied /root/deploy/Makefile can be used for status/tests.

set -e

ACTION="${1:-prepare}"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD_DIR="$SELF_DIR/payload"
HPS_DIR="$PAYLOAD_DIR/hps_mem_test"
TRACE_DIR="$PAYLOAD_DIR/traces"
DEPLOY_DIR="${DEPLOY_DIR:-/root/deploy}"
PREP_SH="$SELF_DIR/fat_prepare_reboot.sh"

copy_if_exists() {
    local src="$1"
    local dst="$2"
    [ -e "$src" ] || return 0
    cp "$src" "$dst"
}

stage_payload() {
    if [ ! -d "$PAYLOAD_DIR" ]; then
        echo "ABORT: payload directory not found: $PAYLOAD_DIR"
        exit 1
    fi

    if [ ! -d "$HPS_DIR" ]; then
        echo "ABORT: staged hps_mem_test directory not found: $HPS_DIR"
        exit 1
    fi

    mkdir -p "$DEPLOY_DIR"

    copy_if_exists "$PAYLOAD_DIR/soc_system.rbf" "$DEPLOY_DIR/"
    copy_if_exists "$PAYLOAD_DIR/good.dtb" "$DEPLOY_DIR/"

    cp "$HPS_DIR"/* "$DEPLOY_DIR/"

    # Copy the board-side wrapper files last so the staged Makefile does not get
    # overwritten by hps_mem_test/Makefile.
    copy_if_exists "$SELF_DIR/Makefile" "$DEPLOY_DIR/Makefile"
    copy_if_exists "$SELF_DIR/fat_bootstrap.sh" "$DEPLOY_DIR/fat_bootstrap.sh"
    copy_if_exists "$SELF_DIR/fat_prepare_reboot.sh" "$DEPLOY_DIR/fat_prepare_reboot.sh"

    if ls "$TRACE_DIR"/*.bin >/dev/null 2>&1; then
        cp "$TRACE_DIR"/*.bin "$DEPLOY_DIR/"
    fi

    chmod +x "$DEPLOY_DIR"/*.sh 2>/dev/null || true

    echo "Staged payload into $DEPLOY_DIR"
}

case "$ACTION" in
    copy)
        stage_payload
        ;;
    prepare|deploy|setup|all|temp)
        stage_payload
        exec bash "$DEPLOY_DIR/fat_prepare_reboot.sh"
        ;;
    *)
        echo "Usage: $0 [copy|prepare]"
        exit 2
        ;;
esac
