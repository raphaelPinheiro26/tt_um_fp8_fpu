# Cocotb module-level testbench for tiny_fp8_unit (controller + pipeline).
# Reference port of sim/tb_fp8_unit.v.
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../../src

VERILOG_SOURCES  = $(SRC_DIR)/tiny_fp8_unit.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_controller.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_elastic_pipeline.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_handshake_reg.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_pre_execute.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_unpack.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_execute_comb.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_normalize.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_round.v

COMPILE_ARGS += -I$(SRC_DIR)
TOPLEVEL = tiny_fp8_unit
COCOTB_TEST_MODULES = test_unit

include $(shell cocotb-config --makefiles)/Makefile.sim
