# Cocotb module-level testbench for fp8_elastic_pipeline.
# Reference port of sim/tb_fp8_golden.v / tb_fp8_elastic.v / tb_fp8_elastic_stream.v.
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../../src

VERILOG_SOURCES  = $(SRC_DIR)/fp8_elastic_pipeline.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_handshake_reg.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_pre_execute.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_unpack.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_execute_comb.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_normalize.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_round.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_div_iter.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_direct_ops.v

COMPILE_ARGS += -I$(SRC_DIR)
TOPLEVEL = fp8_elastic_pipeline
COCOTB_TEST_MODULES = test_pipeline

include $(shell cocotb-config --makefiles)/Makefile.sim
