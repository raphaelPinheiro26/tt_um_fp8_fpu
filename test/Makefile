# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info
#
# Target shuttle: Tiny Tapeout GF 26b (GlobalFoundries gf180mcu).

# defaults
SIM ?= icarus
FST ?= -fst # Use the more efficient FST waveform format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src

# All synthesizable design files (in ../src). header_fp8.v is `included by the
# others; it is found via the -I$(SRC_DIR) flag below, so it is not listed here.
PROJECT_SOURCES  = tt_um_fp8_fpu.v
PROJECT_SOURCES += tiny_fp8_unit.v
PROJECT_SOURCES += fp8_controller.v
PROJECT_SOURCES += fp8_elastic_pipeline.v
PROJECT_SOURCES += fp8_handshake_reg.v
PROJECT_SOURCES += fp8_pre_execute.v
PROJECT_SOURCES += fp8_unpack.v
PROJECT_SOURCES += fp8_execute_comb.v
PROJECT_SOURCES += fp8_normalize.v
PROJECT_SOURCES += fp8_round.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD        = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation (GlobalFoundries gf180mcu):
SIM_BUILD        = sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/gf180mcuD/libs.ref/gf180mcu_fd_sc_mcu7t5v0/verilog/gf180mcu_fd_sc_mcu7t5v0.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Allow `include "header_fp8.v" to be resolved:
COMPILE_ARGS    += -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
