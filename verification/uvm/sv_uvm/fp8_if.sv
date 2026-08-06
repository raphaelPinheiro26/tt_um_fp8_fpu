// ======================================================================
// fp8_if.sv — SystemVerilog interface bundling the tt_um_fp8_fpu pins.
//
// Part of the DIDACTIC SystemVerilog-UVM mirror of the runnable pyuvm
// testbench (../pyuvm). It is written to be correct and readable; running it
// needs a UVM-capable simulator (Questa/Xcelium/VCS, or Verilator's partial
// UVM). The open-source CI uses the pyuvm version instead.
// ======================================================================
`ifndef FP8_IF_SV
`define FP8_IF_SV

interface fp8_if (input logic clk);
    logic        rst_n;
    logic [7:0]  ui_in;     // DATA_IN
    logic [7:0]  uo_out;    // DATA_OUT
    logic [7:0]  uio_in;    // host-driven control (valid/ready/config)
    logic [7:0]  uio_out;   // DUT-driven status
    logic [7:0]  uio_oe;

    // Named control/status bits (see src/tt_um_fp8_fpu.v pin map).
    // uio_in : [0]=IN_VALID [3]=OUT_READY [4]=STICKY_CTRL [5]=STICKY_B [6]=READ_FULL
    // uio_out: [1]=IN_READY [2]=OUT_VALID [7]=FPU_BUSY

    clocking drv_cb @(posedge clk);
        default input #1step output #0;
        output ui_in, uio_in;
        input  uio_out, uo_out;
    endclocking

    clocking mon_cb @(posedge clk);
        default input #1step;
        input ui_in, uio_in, uo_out, uio_out;
    endclocking

    modport DRV (clocking drv_cb, output rst_n);
    modport MON (clocking mon_cb);
endinterface

`endif
