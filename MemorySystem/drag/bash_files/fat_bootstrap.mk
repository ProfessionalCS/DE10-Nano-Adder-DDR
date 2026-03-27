.DEFAULT_GOAL := help
SHELL := /bin/bash

SELF_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SELF_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
BOOTSTRAP_SH := $(SELF_DIR)fat_bootstrap.sh
DEPLOY_DIR ?= /root/deploy
TRACE_DELAY ?= 10
TRACE_FILE ?= dgemm3_lsq88.bin

.PHONY: help temp prepare recover copy post-reboot status smoke trace ddr3 devmem-verify test

temp prepare recover:
	DEPLOY_DIR="$(DEPLOY_DIR)" bash "$(BOOTSTRAP_SH)" prepare

copy:
	DEPLOY_DIR="$(DEPLOY_DIR)" bash "$(BOOTSTRAP_SH)" copy

post-reboot: status
	@echo ""
	@echo "If the board looks sane, continue with:"
	@echo "  cd $(DEPLOY_DIR) && make smoke"
	@echo "  cd $(DEPLOY_DIR) && make test"

status:
	@echo "=== Offline Deploy Status ==="
	@echo "Makefile:  $(SELF_MAKEFILE)"
	@echo "Deploy:    $(DEPLOY_DIR)"
	@echo "FPGA:      $$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null || echo UNKNOWN)"
	@for br in br0 br1 br2 br3; do \
		echo "$$br:        $$(cat /sys/class/fpga_bridge/$$br/state 2>/dev/null || echo MISSING)"; \
	done
	@echo "Service:   $$(systemctl is-active fpga-bridges.service 2>/dev/null || echo not-installed)"
	@if [ -x "$(DEPLOY_DIR)/test_h2f" ]; then \
		cd "$(DEPLOY_DIR)" && ./test_h2f 2>&1 || true; \
	else \
		echo "test_h2f not built yet - run 'make -f $(SELF_MAKEFILE) temp' first"; \
	fi

smoke:
	cd "$(DEPLOY_DIR)" && ./mem_test smoke

trace:
	cd "$(DEPLOY_DIR)" && ./mem_test trace "$(TRACE_FILE)" "$(TRACE_DELAY)"

ddr3:
	cd "$(DEPLOY_DIR)" && ./ddr3_test

devmem-verify:
	cd "$(DEPLOY_DIR)" && ./devmem_verify

test:
	cd "$(DEPLOY_DIR)" && ./manual_test clean test

help:
	@echo "Board-side recover-until-reboot Makefile"
	@echo ""
	@echo "  make -f $(SELF_MAKEFILE) temp"
	@echo "      Copy staged files into $(DEPLOY_DIR), compile everything, install DTB/RBF/service, then stop and tell you to reboot"
	@echo ""
	@echo "  make -f $(SELF_MAKEFILE) copy"
	@echo "      Copy staged files into $(DEPLOY_DIR) only"
	@echo ""
	@echo "  cd $(DEPLOY_DIR) && make post-reboot"
	@echo "      After reboot, show FPGA/bridge status and next commands"
	@echo ""
	@echo "  cd $(DEPLOY_DIR) && make status"
	@echo "  cd $(DEPLOY_DIR) && make smoke"
	@echo "  cd $(DEPLOY_DIR) && make trace TRACE_FILE=dgemm3_lsq88.bin TRACE_DELAY=10"
	@echo "  cd $(DEPLOY_DIR) && make ddr3"
	@echo "  cd $(DEPLOY_DIR) && make devmem-verify"
	@echo "  cd $(DEPLOY_DIR) && make test"
