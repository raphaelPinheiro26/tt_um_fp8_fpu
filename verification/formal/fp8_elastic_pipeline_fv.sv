// ======================================================================
// fp8_elastic_pipeline_fv.sv — End-to-end handshake contract for the whole
// variable-latency FP8 pipeline (unpack → execute → normalize → round, with
// the iterative divider stalling the chain).
//
// The buffer proof (fp8_handshake_reg_fv.sv) already establishes that each
// elastic stage is lossless/order-preserving/non-corrupting. Here we prove
// the SYSTEM-LEVEL handshake properties that compose them:
//   - the output never drops a produced result under back-pressure;
//   - while the iterative divider is running, the pipeline correctly refuses
//     new input (in-order, no overtaking) — a white-box liveness/safety check;
//   - the interesting scenarios (a fast result, and a divide result) are
//     reachable, so nothing is vacuous.
//
// Data-value correctness (does ADD compute A+B?) is intentionally NOT proven
// here: that is the combinational math, exhaustively checked by the golden
// model in ../../sim and ../../test. Formal's job on this design is the
// control/handshake fabric, where simulation coverage is weakest.
//
// Tooling: Yosys + SymbiYosys.  Run: sby -f fp8_elastic_pipeline.sby
// ======================================================================
`default_nettype none
`include "header_fp8.v"

module fp8_elastic_pipeline_fv (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 valid_in,
    input  wire [7:0]           A,
    input  wire [7:0]           B,
    input  wire [`OP_WIDTH-1:0] opcode,
    input  wire [`RD_WIDTH-1:0] rounding_mode,
    input  wire                 ready_in
);
    wire flush = 1'b0;   // never flushed in standalone streaming mode

    wire                   ready_out;
    wire                   valid_out;
    wire [7:0]             result;
    wire [`FLAG_WIDTH-1:0] flags;
    wire [`EXC_WIDTH-1:0]  exceptions;

    fp8_elastic_pipeline dut (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(valid_in), .ready_out(ready_out),
        .A(A), .B(B), .opcode(opcode), .rounding_mode(rounding_mode),
        .valid_out(valid_out), .ready_in(ready_in),
        .result(result), .flags(flags), .exceptions(exceptions)
    );

    // Clean reset in the first cycle.
    reg f_init = 1'b1;
    always @(posedge clk) f_init <= 1'b0;
    always @(posedge clk) if (f_init) assume (rst);

    // Upstream stability: a well-behaved producer holds its request stable
    // while stalled. Mirrors the assumption used in the buffer proof.
    ap_src_stable : assume property (@(posedge clk) disable iff (rst)
        (valid_in && !ready_out) |=>
            (valid_in && $stable(A) && $stable(B)
                      && $stable(opcode) && $stable(rounding_mode)));

    // ==================================================================
    // PROPERTY 1 — OUTPUT PERSISTENCE (no dropped results under back-pressure)
    // The whole reason the pipeline is "elastic": a produced result waits for
    // the consumer without being lost or corrupted.
    // ==================================================================
    ap_out_persist : assert property (@(posedge clk) disable iff (rst)
        (valid_out && !ready_in) |=>
            (valid_out && $stable(result)
                       && $stable(flags) && $stable(exceptions)));

    // ==================================================================
    // PROPERTY 2 — VALID IS STICKY UNTIL CONSUMED.
    // valid_out can only fall on a completed output transfer.
    // ==================================================================
    ap_valid_sticky : assert property (@(posedge clk) disable iff (rst)
        $fell(valid_out) |-> $past(valid_out && ready_in));

    // ==================================================================
    // PROPERTY 3 — IN-ORDER STALL DURING ITERATIVE DIVIDE (white-box).
    // The divider/sqrt is variable-latency; while it iterates (st == ST_BUSY)
    // the pipeline must NOT accept a new operation, guaranteeing results come
    // back in issue order with no overtaking. We reference the DUT's internal
    // state register directly — this is exactly the kind of deep control
    // invariant formal can prove but black-box simulation can only sample.
    // (ST_BUSY == 1'b1 per fp8_elastic_pipeline.v)
    // ==================================================================
    ap_busy_blocks_input : assert property (@(posedge clk) disable iff (rst)
        (dut.st == 1'b1) |-> !ready_out);

    // ==================================================================
    // COVERAGE — reachability of the meaningful scenarios.
    // ==================================================================
    // A fast (single-cycle-class) result can be produced and consumed.
    cp_fast_result : cover property (@(posedge clk) disable iff (rst)
        (valid_out && ready_in));

    // The iterative divider actually engages...
    cp_div_busy : cover property (@(posedge clk) disable iff (rst)
        (dut.st == 1'b1));

    // ...and eventually yields a result downstream (bounded liveness witness).
    cp_div_result : cover property (@(posedge clk) disable iff (rst)
        (dut.st == 1'b1) ##[1:30] (valid_out && ready_in));

    // Back-to-back outputs: two results drained in consecutive cycles
    // (demonstrates the pipeline keeps multiple ops in flight).
    cp_back_to_back : cover property (@(posedge clk) disable iff (rst)
        (valid_out && ready_in) ##1 (valid_out && ready_in));

endmodule

`default_nettype wire
