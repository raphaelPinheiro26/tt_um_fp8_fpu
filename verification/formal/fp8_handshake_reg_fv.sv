// ======================================================================
// fp8_handshake_reg_fv.sv — Formal contract for the depth-1 elastic buffer.
//
// This is the CENTREPIECE proof of the formal track. `fp8_handshake_reg` is
// the single elastic buffer that the whole FP8 pipeline is built from
// (fp8_elastic_pipeline instantiates three of them: RA, RB, RC). If this one
// buffer is proven to be a lossless, order-preserving, non-corrupting
// valid/ready stage, then the pipeline's data integrity reduces to the
// combinational blocks between the buffers — which the exhaustive golden-model
// simulation already covers. That is the compositional argument the formal
// README spells out.
//
// STYLE NOTE: properties are written as IMMEDIATE assertions inside clocked
// always blocks (the "ZipCPU" style), not as concurrent `assert property
// (@(posedge clk) ...)`. Open-source Yosys (no Verific front-end, as shipped in
// the OSS CAD Suite and used in CI) does not parse concurrent SVA, but fully
// supports immediate assertions with $past — so this is the portable form.
//
// Tooling: Yosys + SymbiYosys.  Run: sby -f fp8_handshake_reg.sby
// ======================================================================
`default_nettype none

module fp8_handshake_reg_fv #(
    parameter DATA_WIDTH = 4
) (
    input  wire                   clk,
    input  wire                   rst,
    input  wire                   valid_in,
    input  wire [DATA_WIDTH-1:0]  data_in,
    input  wire                   ready_in
);
    // Flush is a real port but is only pulsed on pipeline flush, which never
    // happens in standalone streaming mode (tt_um_fp8_fpu ties flush=0). We
    // hold it low so the steady-state contract is clean.
    wire flush = 1'b0;

    wire                  ready_out;
    wire                  valid_out;
    wire [DATA_WIDTH-1:0] data_out;

    // ---------------- Device under proof ----------------
    fp8_handshake_reg #(.DATA_WIDTH(DATA_WIDTH)) dut (
        .clk       (clk),
        .rst       (rst),
        .flush     (flush),
        .valid_in  (valid_in),
        .ready_out (ready_out),
        .data_in   (data_in),
        .valid_out (valid_out),
        .data_out  (data_out),
        .ready_in  (ready_in)
    );

    // ---------------- Formal housekeeping ----------------
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    // Force a clean reset in the very first cycle, then let rst float free.
    always @(posedge clk) if (!f_past_valid) assume (rst);

    // Handshake transfer events.
    wire acc_in  = valid_in  & ready_out;   // an item is accepted upstream
    wire acc_out = valid_out & ready_in;    // an item is drained downstream

    // Occupancy shadow model (depth-1: must stay in {0,1}).
    reg [1:0] occ;
    always @(posedge clk or posedge rst) begin
        if (rst) occ <= 2'd0;
        else     occ <= occ + acc_in - acc_out;
    end

    // ==================================================================
    // PROPERTY 1 — ready_out is exactly the intended combinational formula.
    // Documents intent: accept when empty OR when draining.
    // ==================================================================
    always @(*)
        ap_ready_formula : assert (ready_out == (ready_in | ~valid_out));

    always @(posedge clk) if (f_past_valid && !rst) begin
        // ==============================================================
        // ENVIRONMENT ASSUMPTION — upstream valid/ready contract.
        // A well-behaved producer keeps (valid_in, data_in) stable while it is
        // stalled (asserted but not yet accepted). Without this no buffer can
        // be lossless.
        // ==============================================================
        if ($past(valid_in && !ready_out))
            ap_src_stable : assume (valid_in && data_in == $past(data_in));

        // ==============================================================
        // PROPERTY 2 — OUTPUT PERSISTENCE (no dropped beats under back-pressure)
        // A presented result held under back-pressure stays valid, data stable.
        // ==============================================================
        if ($past(valid_out && !ready_in))
            ap_persist : assert (valid_out && data_out == $past(data_out));

        // ==============================================================
        // PROPERTY 3 — NO SPURIOUS OUTPUT (no data creation).
        // valid_out rises only as a direct consequence of an accepted input.
        // ==============================================================
        if (valid_out && !$past(valid_out))
            ap_no_create : assert ($past(acc_in));

        // ==============================================================
        // PROPERTY 4 — DATA INTEGRITY (no corruption).
        // data_out may only ever change to the just-accepted data_in.
        // ==============================================================
        if (data_out != $past(data_out))
            ap_data_src : assert ($past(acc_in) && data_out == $past(data_in));

        // ==============================================================
        // PROPERTY 5 — DEPTH-1 OCCUPANCY INVARIANT (no loss/duplication).
        // An independent accounting of in/out transfers stays in {0,1} and
        // matches valid_out exactly.
        // ==============================================================
        ap_occ_bound : assert (occ <= 2'd1);
        ap_occ_match : assert ((occ == 2'd1) == valid_out);
    end

    // ==================================================================
    // COVERAGE — prove the interesting scenarios are reachable (so the
    // assertions above are not vacuously true).
    // ==================================================================
    always @(posedge clk) if (f_past_valid && !rst) begin
        cp_xfer_out     : cover (acc_out);                        // a drain
        cp_flowthrough  : cover (acc_out && acc_in);              // load+drain same cycle
        cp_backpressure : cover ($past(valid_out && !ready_in) && acc_out); // held then drained
    end

endmodule

`default_nettype wire
