# ──────────────────────────────────────────────────────────
# Makefile — Simple Adder (DE10-Nano)
#
# Usage:
#   make rbf          Find newest RBF → copy into drag/
#   make stage        Package drag/ folder for SD card
#   make clean        Remove build artifacts
# ──────────────────────────────────────────────────────────

QUARTUS_DIR := quatus
RBF_OUT     := $(QUARTUS_DIR)/output_files/soc_system.rbf
RBF_ROOT    := $(QUARTUS_DIR)/soc_system.rbf
SOF_FILE    := $(QUARTUS_DIR)/output_files/DE10_NANO_SoC_GHRD.sof
DRAG_DIR    := drag

.DEFAULT_GOAL := help

# ── Find newest RBF and copy into drag/ ─────────────────
#    Checks both output_files/ and quatus/ root.
#    Picks the newest RBF. Errors if none found.
#    Warns if the SOF is newer than the RBF.
.PHONY: rbf
rbf:
	@RBF=""; \
	if [ -f "$(RBF_OUT)" ] && [ -f "$(RBF_ROOT)" ]; then \
		if [ "$(RBF_OUT)" -nt "$(RBF_ROOT)" ]; then \
			RBF="$(RBF_OUT)"; \
		else \
			RBF="$(RBF_ROOT)"; \
		fi; \
	elif [ -f "$(RBF_OUT)" ]; then \
		RBF="$(RBF_OUT)"; \
	elif [ -f "$(RBF_ROOT)" ]; then \
		RBF="$(RBF_ROOT)"; \
	else \
		echo "ERROR: No RBF found in $(QUARTUS_DIR)/output_files/ or $(QUARTUS_DIR)/"; \
		echo "       Generate the RBF from Quartus first."; \
		exit 1; \
	fi; \
	echo "Using RBF: $$RBF"; \
	if [ -f "$(SOF_FILE)" ] && [ "$(SOF_FILE)" -nt "$$RBF" ]; then \
		echo "WARNING: SOF is newer than RBF — you may need to regenerate the RBF in Quartus."; \
	fi; \
	cp "$$RBF" "$(DRAG_DIR)/soc_system.rbf" && \
	echo "Copied to $(DRAG_DIR)/soc_system.rbf"

# ── Stage: copy RBF into drag/ so it's ready to drop ─────
.PHONY: stage
stage: rbf 
	@echo ""
	@echo "drag/ folder is ready. Copy it onto the SD card FAT partition."
	@echo "On the board:  cd /mnt/bootfat/drag && make deploy"

# ── Clean ─────────────────────────────────────────────────
.PHONY: clean
clean:
	rm -f $(DRAG_DIR)/soc_system.rbf

# ── Help ──────────────────────────────────────────────────
.PHONY: help
help:
	@echo "Simple Adder — Build & Deploy"
	@echo ""
	@echo "  make rbf     Find newest RBF, warn if stale, copy to drag/"
	@echo "  make stage   Same as rbf + ready message"
	@echo "  make clean   Remove staged RBF"
	@echo ""
	@echo "Workflow:"
	@echo "  1. Compile in Quartus (transfer_quatus project)"
	@echo "  2. make stage"
	@echo "  3. Copy drag/ folder onto SD card FAT partition"
	@echo "  4. On board: cd /mnt/bootfat/drag && make deploy"
	@echo "  5. reboot"
	@echo "  6. cd /root/adder && make test"
