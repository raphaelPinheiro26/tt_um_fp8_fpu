# Cocotb module-level testbench for fp8_handshake_reg (elastic skid buffer).
# Reference port of sim/tb_handshake_elastic.v. DATA_WIDTH is widened to 8 so
# a counter can be tracked byte-exact through the buffer.
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../../src

VERILOG_SOURCES = $(SRC_DIR)/fp8_handshake_reg.v

COMPILE_ARGS += -I$(SRC_DIR)
COMPILE_ARGS += -Pfp8_handshake_reg.DATA_WIDTH=8
TOPLEVEL = fp8_handshake_reg
COCOTB_TEST_MODULES = test_handshake

include $(shell cocotb-config --makefiles)/Makefile.sim
