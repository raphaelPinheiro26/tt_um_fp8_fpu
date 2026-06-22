/*
 * tt_um_fp8_fpu.v - Tiny Tapeout top-level wrapper for the FP8 (E4M3) FPU
 *                   STREAMING / PIPELINED I/O version
 *
 * Copyright (c) 2026 Raphael Lopes Pinheiro
 * SPDX-License-Identifier: Apache-2.0
 *
 * ---------------------------------------------------------------------------
 * WHY A STREAMING WRAPPER
 * ---------------------------------------------------------------------------
 * Tiny Tapeout exposes a fixed pin budget (ui_in[8], uo_out[8], uio[8],
 * clk, rst_n, ena). The FPU core (tiny_fp8_unit) is an ELASTIC, pipelined
 * datapath that can hold several operations in flight. The previous wrapper
 * loaded one operation, WAITED for its result, then read it back (1 op in
 * flight) — which hid the whole point of the pipeline.
 *
 * This version decouples input from output with two independent valid/ready
 * handshakes, so the host (an RP2040 / ESP32 / STM32) can keep feeding new
 * operations while draining results. Multiple ops stay in flight and the
 * measured initiation interval (II, cycles/op) approaches the byte count per
 * operation — down to 1 in the best case.
 *
 * ---------------------------------------------------------------------------
 * PIN MAP (see docs/PROTOCOL.md for the full cycle-by-cycle protocol)
 * ---------------------------------------------------------------------------
 *  ui_in[7:0]   DATA_IN   : input byte stream (A, then B, then CTRL)
 *  uo_out[7:0]  DATA_OUT  : output byte stream (result, [flags, exceptions])
 *
 *  uio_in[0]    IN_VALID  : host asserts when ui_in holds a valid byte
 *  uio_out[1]   IN_READY  : core can accept a byte this cycle
 *  uio_out[2]   OUT_VALID : DATA_OUT holds a valid result byte
 *  uio_in[3]    OUT_READY : host consumed the current DATA_OUT byte
 *  uio_in[4]    STICKY_CTRL : reuse last {rm,opcode}; do NOT send CTRL byte
 *  uio_in[5]    STICKY_B    : reuse last B operand; do NOT send B byte
 *  uio_in[6]    READ_FULL   : output 3 bytes/op (result,flags,exc) instead of 1
 *  uio_out[7]   FPU_BUSY    : core busy flag (observability)
 *
 *  uio_oe = 8'b1000_0110  -> uio[7],[2],[1] are outputs; the rest are inputs.
 *
 * CTRL byte layout: { rm = ui_in[7:5], opcode = ui_in[4:0] }
 * FP8 E4M3 encoding (header_fp8.v): [7]=sign [6:3]=exp(bias 7) [2:0]=mant.
 *
 * STICKY USAGE: to reuse B and/or CTRL across ops, the host must first send
 * one FULL operation with both sticky bits LOW (loads B/CTRL into the holding
 * registers), then raise the sticky bits. Keep the sticky bits STABLE during
 * the bytes of any single operation; change them only between operations.
 * ---------------------------------------------------------------------------
 */

`default_nettype none
`include "header_fp8.v"

module tt_um_fp8_fpu (
    input  wire [7:0] ui_in,    // Dedicated inputs  (DATA_IN)
    output wire [7:0] uo_out,   // Dedicated outputs (DATA_OUT)
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (1=output, 0=input)
    input  wire       ena,      // always 1 when the design is powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset, active LOW
);

    // ----------------------------------------------------------------------
    // Reset polarity adapter (core uses active-HIGH reset).
    // ----------------------------------------------------------------------
    wire rst = ~rst_n;

    // ----------------------------------------------------------------------
    // Named host-side control bits (see pin map above).
    // ----------------------------------------------------------------------
    wire host_in_valid   = uio_in[0];
    wire host_out_ready  = uio_in[3];
    wire cfg_sticky_ctrl = uio_in[4];
    wire cfg_sticky_b    = uio_in[5];
    wire cfg_read_full   = uio_in[6];

    // ----------------------------------------------------------------------
    // Operand / control holding registers (also used for sticky reuse).
    // ----------------------------------------------------------------------
    reg [7:0]           a_reg;
    reg [7:0]           b_reg;
    reg [`OP_WIDTH-1:0] opcode_reg;   // 5 bits
    reg [2:0]           rm_reg;       // 3 bits

    // ----------------------------------------------------------------------
    // Core handshake wires.
    // ----------------------------------------------------------------------
    wire                    issue_ready;
    wire                    wb_valid;
    wire                    wb_ready;
    wire [7:0]              wb_result;
    wire [`FLAG_WIDTH-1:0]  wb_flags;
    wire [`EXC_WIDTH-1:0]   wb_exceptions;
    wire [4:0]              wb_rd;        // unused (no register file on chip)
    wire                    fpu_busy;

    // ======================================================================
    // INPUT SIDE: byte deserializer -> issue handshake
    //
    // Byte sequence per op: A [, B] [, CTRL]   (B/CTRL skipped if sticky).
    //   in_needed = 1 + !sticky_b + !sticky_ctrl   (1..3 bytes)
    // The LAST byte is issued combinationally: the core latches the live
    // field straight from ui_in on the same edge it arrives, so II == bytes.
    // ======================================================================
    reg [1:0] in_count;   // bytes accepted so far in the current op (0..2)

    wire [1:0] in_needed = 2'd1
                         + (cfg_sticky_b    ? 2'd0 : 2'd1)
                         + (cfg_sticky_ctrl ? 2'd0 : 2'd1);
    wire in_last = (in_count == (in_needed - 2'd1));

    // Which field does the current (in_count) byte target?
    wire live_ctrl = (in_count == 2'd1 && cfg_sticky_b) || (in_count == 2'd2);

    // Fields presented to the core. The "live" field comes from ui_in this
    // cycle; the others come from the holding registers (registered earlier,
    // or reused via sticky).
    wire [7:0]           issue_A_w      = (in_count == 2'd0) ? ui_in : a_reg;
    wire [7:0]           issue_B_w      = (in_count == 2'd1 && !cfg_sticky_b)
                                            ? ui_in : b_reg;
    wire [`OP_WIDTH-1:0] issue_opcode_w = live_ctrl ? ui_in[`OP_WIDTH-1:0]
                                                    : opcode_reg;
    wire [2:0]           issue_rm_w     = live_ctrl ? ui_in[7:5] : rm_reg;

    // Issue only when the last byte of the op is present.
    wire issue_valid = host_in_valid & in_last;

    // Ready for a byte: always while collecting; on the last byte the transfer
    // only completes if the core also accepts (issue_ready).
    wire in_ready = in_last ? issue_ready : 1'b1;

    wire in_xfer = host_in_valid & in_ready;   // a byte is taken this cycle

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            in_count   <= 2'd0;
            a_reg      <= 8'h00;
            b_reg      <= 8'h00;
            opcode_reg <= {`OP_WIDTH{1'b0}};
            rm_reg     <= 3'b000;
        end else if (in_xfer) begin
            // Register the incoming byte into its mapped field (keeps the
            // value around for sticky reuse on later ops).
            if (in_count == 2'd0)
                a_reg <= ui_in;
            else if (in_count == 2'd1 && !cfg_sticky_b)
                b_reg <= ui_in;
            else begin
                rm_reg     <= ui_in[7:5];
                opcode_reg <= ui_in[`OP_WIDTH-1:0];
            end
            // Advance within the op, or wrap to the next op after issue.
            if (in_last) in_count <= 2'd0;
            else         in_count <= in_count + 2'd1;
        end
    end

    // ======================================================================
    // CORE
    // ======================================================================
    tiny_fp8_unit u_fpu (
        .clk           (clk),
        .rst           (rst),
        .issue_valid   (issue_valid),
        .issue_ready   (issue_ready),
        .issue_A       (issue_A_w),
        .issue_B       (issue_B_w),
        .issue_opcode  (issue_opcode_w),
        .issue_rm      (issue_rm_w),
        .issue_rd      (5'b00000),       // no destination register on chip
        .wb_valid      (wb_valid),
        .wb_ready      (wb_ready),
        .wb_result     (wb_result),
        .wb_flags      (wb_flags),
        .wb_exceptions (wb_exceptions),
        .wb_rd         (wb_rd),
        .fpu_busy      (fpu_busy),
        .flush         (1'b0)            // never flush in standalone mode
    );

    // ======================================================================
    // OUTPUT SIDE: writeback handshake -> byte serializer
    //
    // Byte sequence per result: result [, flags, exceptions]  (the last two
    // only when READ_FULL=1).  out_needed = READ_FULL ? 3 : 1.
    // ======================================================================
    reg [7:0]              res_reg;
    reg [`FLAG_WIDTH-1:0]  flg_reg;
    reg [`EXC_WIDTH-1:0]   exc_reg;
    reg                    out_busy;     // a result is being emitted
    reg [1:0]              out_count;    // 0=result, 1=flags, 2=exceptions

    wire [1:0] out_needed = cfg_read_full ? 2'd3 : 2'd1;
    wire       out_last   = (out_count == (out_needed - 2'd1));

    wire out_valid = out_busy;
    wire out_xfer  = out_valid & host_out_ready;          // host took a byte
    wire emit_done = out_xfer & out_last;                  // last byte leaving

    // Accept a new writeback when idle, or exactly as the current result's
    // last byte is consumed (back-to-back, keeps the output at 1 result/cyc).
    assign wb_ready = (~out_busy) | emit_done;
    wire   accept_wb = wb_valid & wb_ready;

    reg [7:0] data_out;
    always @(*) begin
        case (out_count)
            2'd0:    data_out = res_reg;
            2'd1:    data_out = {1'b0, flg_reg};       // 1 + 7 = 8 bits
            default: data_out = {3'b000, exc_reg};     // 3 + 5 = 8 bits
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            out_busy  <= 1'b0;
            out_count <= 2'd0;
            res_reg   <= 8'h00;
            flg_reg   <= {`FLAG_WIDTH{1'b0}};
            exc_reg   <= {`EXC_WIDTH{1'b0}};
        end else begin
            // advance through the output bytes
            if (out_xfer && !out_last)
                out_count <= out_count + 2'd1;

            if (accept_wb) begin
                // latch a fresh result (overrides emit_done -> stays busy)
                res_reg   <= wb_result;
                flg_reg   <= wb_flags;
                exc_reg   <= wb_exceptions;
                out_count <= 2'd0;
                out_busy  <= 1'b1;
            end else if (emit_done) begin
                out_busy  <= 1'b0;
            end
        end
    end

    // ======================================================================
    // PIN OUTPUTS
    // ======================================================================
    assign uo_out  = data_out;

    //  uio_out[7]=fpu_busy, [2]=out_valid, [1]=in_ready, others 0
    assign uio_out = {fpu_busy, 4'b0000, out_valid, in_ready, 1'b0};
    assign uio_oe  = 8'b1000_0110;

    // Tie off unused nets to keep the synthesiser quiet.
    wire _unused = &{ena, uio_in[7], uio_in[2], wb_rd, 1'b0};

endmodule

`default_nettype wire
