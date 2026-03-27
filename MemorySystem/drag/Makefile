# ══════════════════════════════════════════════════════════
#  Simple Adder — DE10-Nano Drag-and-Drop Deploy
# ══════════════════════════════════════════════════════════
#
#  How to use:
#    1. Compile the Quartus project → get soc_system.rbf
#       (copy it into this folder next to this Makefile)
#    2. Copy this whole folder onto the SD card FAT partition
#    3. Boot the board, SSH in, then:
#
#         mount /dev/mmcblk0p1 /mnt/bootfat
#         cd /mnt/bootfat/drag
#         make deploy
#         reboot
#
#    4. After reboot:
#
#         cd /root/adder
#         make test
#
# ══════════════════════════════════════════════════════════

SHELL      := /bin/bash
SELF_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
DEPLOY_DIR := /root/adder
BOOTFAT    := /mnt/bootfat

# Auto-discover every .c file in c_progs/
C_SRCS := $(wildcard $(SELF_DIR)c_progs/*.c)
C_BINS := $(patsubst $(SELF_DIR)c_progs/%.c,$(DEPLOY_DIR)/%,$(C_SRCS))

.DEFAULT_GOAL := help

# ────────────────────────────────────────────────────────
#  deploy  —  one command does everything
# ────────────────────────────────────────────────────────
.PHONY: deploy
deploy: install-rbf fix-dtb compile install-service bridges setup-network
	@cp "$(SELF_DIR)Makefile" "$(DEPLOY_DIR)/Makefile" 2>/dev/null || true
	@echo ""
	@echo "════════════════════════════════════════════"
	@echo " Deploy complete.  Reboot, then:"
	@echo "   cd $(DEPLOY_DIR) && make test"
	@echo "════════════════════════════════════════════"

# ────────────────────────────────────────────────────────
#  compile  —  build every .c in c_progs/
# ────────────────────────────────────────────────────────
.PHONY: compile
compile: $(C_BINS)
	@echo "All C programs compiled into $(DEPLOY_DIR)/"

$(DEPLOY_DIR)/%: $(SELF_DIR)c_progs/%.c
	@mkdir -p $(DEPLOY_DIR)
	gcc -O2 -o $@ $<
	@echo "  built $(@F)"

# ────────────────────────────────────────────────────────
#  bridges  —  enable HPS ↔ FPGA bridges
# ────────────────────────────────────────────────────────
.PHONY: bridges
bridges: $(DEPLOY_DIR)/enable_bridges
	$(DEPLOY_DIR)/enable_bridges

# ────────────────────────────────────────────────────────
#  install-rbf  —  copy bitstream + DTB onto boot FAT
# ────────────────────────────────────────────────────────
.PHONY: install-rbf
install-rbf:
	@mkdir -p $(BOOTFAT)
	@mountpoint -q $(BOOTFAT) 2>/dev/null || mount /dev/mmcblk0p1 $(BOOTFAT)
	@if [ -f "$(SELF_DIR)soc_system.rbf" ]; then \
		cp "$(SELF_DIR)soc_system.rbf" "$(BOOTFAT)/soc_system.rbf" && \
		echo "Installed soc_system.rbf"; \
	else \
		echo "NOTE: no soc_system.rbf found — compile in Quartus first"; \
	fi
	@if [ -f "$(SELF_DIR)socfpga_cyclone5_de0_nano_soc.dtb" ]; then \
		cp "$(SELF_DIR)socfpga_cyclone5_de0_nano_soc.dtb" \
		   "$(BOOTFAT)/socfpga_cyclone5_de0_nano_soc.dtb" && \
		echo "Installed DTB"; \
	fi
	@sync

# ────────────────────────────────────────────────────────
#  test  —  run the adder verification
# ────────────────────────────────────────────────────────
.PHONY: test
test: $(DEPLOY_DIR)/adder_test $(DEPLOY_DIR)/enable_bridges
	@$(DEPLOY_DIR)/enable_bridges > /dev/null 2>&1
	$(DEPLOY_DIR)/adder_test

# ────────────────────────────────────────────────────────
#  Debug / Status
# ────────────────────────────────────────────────────────
.PHONY: status
status: $(DEPLOY_DIR)/bridge_probe $(DEPLOY_DIR)/pio_probe $(DEPLOY_DIR)/enable_bridges
	@$(DEPLOY_DIR)/enable_bridges > /dev/null 2>&1
	@echo "── Bridge Status ──"
	@$(DEPLOY_DIR)/bridge_probe
	@echo ""
	@echo "── PIO Status ──"
	@$(DEPLOY_DIR)/pio_probe

.PHONY: diag
diag: $(DEPLOY_DIR)/reset_diag
	$(DEPLOY_DIR)/reset_diag

.PHONY: check-mem
check-mem:
	bash $(SELF_DIR)bash_files/check_mem.sh

# ────────────────────────────────────────────────────────
#  Recovery / Board Fixes
# ────────────────────────────────────────────────────────
.PHONY: recover
recover:
	bash $(SELF_DIR)bash_files/recover_board.sh

.PHONY: fix-boot
fix-boot:
	bash $(SELF_DIR)bash_files/fix_boot.sh

# ────────────────────────────────────────────────────────
#  fix-dtb  —  patch DTB to enable FPGA bridges at boot
#    Decompiles the DTB, sets all bridge nodes to
#    status="okay" with bridge-enable=<1>, recompiles.
#    (from golden main branch deploy_to_board.sh)
# ────────────────────────────────────────────────────────
DTB_FILE := $(BOOTFAT)/socfpga_cyclone5_de0_nano_soc.dtb

.PHONY: fix-dtb
fix-dtb:
	@mkdir -p $(BOOTFAT)
	@mountpoint -q $(BOOTFAT) 2>/dev/null || mount /dev/mmcblk0p1 $(BOOTFAT)
	@if [ ! -f "$(DTB_FILE)" ]; then \
		echo "ERROR: DTB not found at $(DTB_FILE)"; \
		exit 1; \
	fi
	@[ -f "$(DTB_FILE).orig" ] || cp "$(DTB_FILE)" "$(DTB_FILE).orig"
	@echo "Decompiling DTB ..."
	@dtc -I dtb -O dts -o /tmp/_adder_deploy.dts "$(DTB_FILE)" 2>/dev/null
	@echo "Patching bridge nodes ..."
	@sed -i 's/status = "disabled"/status = "okay"/g' /tmp/_adder_deploy.dts
	@if ! grep -q 'bridge-enable' /tmp/_adder_deploy.dts; then \
		awk '\
			/fpga-bridge@ff400000|fpga-bridge@ff500000|fpga-bridge@ff600000|fpga2sdram/ { in_bridge=1 } \
			{ \
				print; \
				if (in_bridge && /status = "okay"/) { print "\t\t\tbridge-enable = <1>;"; in_bridge=0 } \
			}' /tmp/_adder_deploy.dts > /tmp/_adder_deploy_fixed.dts; \
	else \
		echo "  bridge-enable already present, skipping awk"; \
		cp /tmp/_adder_deploy.dts /tmp/_adder_deploy_fixed.dts; \
	fi
	@echo "Recompiling DTB ..."
	@dtc -f -I dts -O dtb -o /tmp/_adder_deploy.dtb /tmp/_adder_deploy_fixed.dts 2>/dev/null
	@cp /tmp/_adder_deploy.dtb "$(DTB_FILE)"
	@rm -f /tmp/_adder_deploy.dts /tmp/_adder_deploy_fixed.dts /tmp/_adder_deploy.dtb
	@sync
	@echo "DTB patched (bridges enabled)"

# ────────────────────────────────────────────────────────
#  install-service  —  systemd auto-bridge-fix at boot
#    (from golden main branch fat_prepare_reboot.sh)
# ────────────────────────────────────────────────────────
.PHONY: install-service
install-service: $(DEPLOY_DIR)/enable_bridges
	@echo "Installing fpga-bridges.service ..."
	@printf '#!/bin/bash\nLOG=/root/adder/bridge_boot.log\necho "$$(date): enable_bridges starting" > "$$LOG"\n/root/adder/enable_bridges >> "$$LOG" 2>&1\nRET=$$?\necho "$$(date): enable_bridges exited $$RET" >> "$$LOG"\nexit $$RET\n' > $(DEPLOY_DIR)/enable_bridges_boot.sh
	@chmod +x $(DEPLOY_DIR)/enable_bridges_boot.sh
	@printf '[Unit]\nDescription=Enable FPGA bridges via /dev/mem register writes\nAfter=multi-user.target\n\n[Service]\nType=oneshot\nExecStart=/root/adder/enable_bridges_boot.sh\nRemainAfterExit=yes\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/fpga-bridges.service
	@systemctl daemon-reload
	@systemctl enable fpga-bridges.service 2>/dev/null || true
	@echo "fpga-bridges.service installed + enabled"

# ────────────────────────────────────────────────────────
#  setup-network  —  write static IP and bring up eth0
#    Writes /etc/network/interfaces so SSH is reachable
#    at 192.168.0.2 after every reboot.
#    Also brings eth0 up immediately so you don't need
#    to reboot just to get SSH back.
# ────────────────────────────────────────────────────────
ETH_IP      := 192.168.0.2
ETH_NETMASK := 255.255.255.0
ETH_GW      := 192.168.0.1

.PHONY: setup-network
setup-network:
	@echo "Configuring static IP $(ETH_IP) on eth0 ..."
	@printf 'auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet static\n\taddress $(ETH_IP)\n\tnetmask $(ETH_NETMASK)\n\tgateway $(ETH_GW)\n' \
		> /etc/network/interfaces
	@echo "  Wrote /etc/network/interfaces"
	@ifdown eth0 2>/dev/null || true
	@ifup eth0 2>/dev/null || true
	@echo "  eth0 brought up ($(ETH_IP))"

.PHONY: patch-boot
patch-boot:
	bash $(SELF_DIR)bash_files/patch_boot.sh

.PHONY: fat-bootstrap
fat-bootstrap:
	bash $(SELF_DIR)bash_files/fat_bootstrap.sh

# ────────────────────────────────────────────────────────
#  clean / help
# ────────────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -rf $(DEPLOY_DIR)

.PHONY: help
help:
	@echo "Simple Adder — DE10-Nano Deploy"
	@echo ""
	@echo "  make deploy          Full deploy: RBF + DTB + compile + service + bridges"
	@echo "  make test            Run adder verification (PIO + DDR3 + DEADBEEF)"
	@echo "  make compile         Compile all c_progs/*.c into $(DEPLOY_DIR)/"
	@echo "  make bridges         Enable HPS ↔ FPGA bridges"
	@echo ""
	@echo "  make fix-dtb         Patch DTB to enable bridges at boot"
	@echo "  make install-service Install systemd auto-bridge service"
	@echo "  make setup-network   Write static IP 192.168.0.2 + bring up eth0"
	@echo ""
	@echo "  make status          Show bridge + PIO status"
	@echo "  make diag            Run reset diagnostics"
	@echo "  make check-mem       Check DDR3 memory regions"
	@echo ""
	@echo "  make recover         Run board recovery script"
	@echo "  make fix-boot        Fix boot configuration"
	@echo "  make patch-boot      Patch boot files"
	@echo "  make fat-bootstrap   Bootstrap FAT partition"
	@echo ""
	@echo "  make clean           Remove $(DEPLOY_DIR)"
