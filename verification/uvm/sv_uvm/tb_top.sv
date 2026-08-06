// ======================================================================
// tb_top.sv — Top module for the SystemVerilog-UVM mirror.
//
// DIDACTIC: needs a UVM-capable simulator. Example (Questa):
//   vlog -sv +incdir+$UVM_HOME/src $UVM_HOME/src/uvm.sv \
//        ../../../src/*.v fp8_if.sv fp8_uvm_pkg.sv tb_top.sv
//   vsim -c tb_top +UVM_TESTNAME=fp8_base_test -do "run -all; quit"
//
// The open-source CI runs the equivalent pyuvm testbench in ../pyuvm instead.
// ======================================================================
`timescale 1ns/1ps
`include "fp8_if.sv"

module tb_top;
    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import fp8_uvm_pkg::*;

    logic clk = 0;
    always #5 clk = ~clk;         // 100 MHz test clock

    fp8_if vif (.clk(clk));

    // Reset generation (active-low, mirrors the pyuvm BFM.reset()).
    initial begin
        vif.rst_n  = 0;
        vif.ui_in  = 0;
        vif.uio_in = BASE_UIO;     // OUT_READY=1, READ_FULL=1
        repeat (5) @(posedge clk);
        vif.rst_n  = 1;
    end

    // DUT
    tt_um_fp8_fpu dut (
        .ui_in   (vif.ui_in),
        .uo_out  (vif.uo_out),
        .uio_in  (vif.uio_in),
        .uio_out (vif.uio_out),
        .uio_oe  (vif.uio_oe),
        .ena     (1'b1),
        .clk     (clk),
        .rst_n   (vif.rst_n)
    );

    initial begin
        uvm_config_db#(virtual fp8_if)::set(null, "*", "vif", vif);
        run_test("fp8_base_test");   // or +UVM_TESTNAME=fp8_full_random_test
    end
endmodule
