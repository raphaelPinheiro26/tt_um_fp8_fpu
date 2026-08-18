# pyuvm / cocotb testbench for the FP8 streaming top-level (tt_um_fp8_fpu).
#
#   make                       # Fp8SmokeTest (default, fast)
#   make TEST=Fp8ArithTest     # ADD/SUB/MUL/DIV, all rounding modes
#   make TEST=Fp8FullRandomTest# all 18 opcodes, all rounding modes
#   make SIM=verilator         # switch simulator (default: icarus)
#   make clean
#
# Requires: iverilog (or verilator) + `pip install -r ../requirements.txt`.

SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../../src

VERILOG_SOURCES  = $(SRC_DIR)/tt_um_fp8_fpu.v
VERILOG_SOURCES += $(SRC_DIR)/tiny_fp8_unit.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_controller.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_elastic_pipeline.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_handshake_reg.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_pre_execute.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_unpack.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_execute_comb.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_normalize.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_round.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_div_iter.v
VERILOG_SOURCES += $(SRC_DIR)/fp8_direct_ops.v

COMPILE_ARGS += -I$(SRC_DIR)
TOPLEVEL = tt_um_fp8_fpu
COCOTB_TEST_MODULES = fp8_test

# Select which uvm_test to run (read by fp8_test.py at runtime).
TEST ?= Fp8SmokeTest
export TEST

include $(shell cocotb-config --makefiles)/Makefile.sim
