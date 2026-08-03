# Cocotb module-level testbench for fp8_controller (issue/writeback + rd FIFO).
# Reference port of sim/tb_fp8_controller.v. The pipeline the controller talks
# to is modelled inside test_controller.py (the Verilog tb used a pipe_stub).
SIM ?= icarus
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../../../src

VERILOG_SOURCES = $(SRC_DIR)/fp8_controller.v

COMPILE_ARGS += -I$(SRC_DIR)
TOPLEVEL = fp8_controller
COCOTB_TEST_MODULES = test_controller

include $(shell cocotb-config --makefiles)/Makefile.sim
