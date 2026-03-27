VERILATOR ?= verilator
LLCD_SRCS := MemorySystem/cacheDataTypes.sv MemorySystem/llcd.sv
LLCD_TB_SRC := MemorySystem/llcdTb.sv
OBJ_DIR := obj_dir

.PHONY: all compile run clean

all: compile

compile:
	mkdir -p $(OBJ_DIR)
	$(VERILATOR) --binary --top-module llcdTb -Mdir $(OBJ_DIR) $(LLCD_SRCS) $(LLCD_TB_SRC)

run: compile
	$(OBJ_DIR)/VllcdTb

clean:
	rm -rf obj_dir