// ======================================================================
// tiny_fp8_unit.v — Top-level da FPU FP8 E4M3
//
// Integra fp8_controller + fp8_elastic_pipeline.
//
// DIAGRAMA DE BLOCOS:
//
//  ┌──────────────────────────────────────────────────────────────────┐
//  │                       tiny_fp8_unit                              │
//  │                                                                  │
//  │  ┌──────────────────┐       ┌──────────────────────────────┐    │
//  │  │  fp8_controller  │──────►│   fp8_elastic_pipeline       │    │
//  │  │                  │◄──────│  (reg_r0_r1 → r1_r2 → r2_r3)│    │
//  │  └──────────────────┘       └──────────────────────────────┘    │
//  │        ▲  ▼                                                      │
//  └────────┼──┼──────────────────────────────────────────────────────┘
//           │  │
//       RISC-V Core / Testbench
//
// Parâmetros:
//   RD_FIFO_DEPTH – profundidade da FIFO de rd (default 8)
//
// Formato FP8 E4M3:
//   [7]=sinal, [6:3]=expoente(bias=7), [2:0]=mantissa
//   Inf: exp=1111, mant=000
//   NaN: exp=1111, mant≠000
// ======================================================================
`include "header_fp8.v"

module tiny_fp8_unit #(
    parameter RD_FIFO_DEPTH = 8
) (
    input  wire                    clk,
    input  wire                    rst,

    // Interface com o Core (issue)
    input  wire                    issue_valid,
    output wire                    issue_ready,
    input  wire [7:0]              issue_A,
    input  wire [7:0]              issue_B,
    input  wire [`OP_WIDTH-1:0]    issue_opcode,
    input  wire [2:0]              issue_rm,
    input  wire [4:0]              issue_rd,

    // Interface com o Core (writeback)
    output wire                    wb_valid,
    input  wire                    wb_ready,
    output wire [7:0]              wb_result,
    output wire [`FLAG_WIDTH-1:0]  wb_flags,
    output wire [`EXC_WIDTH-1:0]   wb_exceptions,
    output wire [4:0]              wb_rd,

    // Controle
    output wire                    fpu_busy,
    input  wire                    flush
);

    // Fios internos controller ↔ pipeline
    wire                    pipe_valid_in;
    wire                    pipe_ready_out;
    wire [7:0]              pipe_A;
    wire [7:0]              pipe_B;
    wire [`OP_WIDTH-1:0]    pipe_opcode;
    wire [`RD_WIDTH-1:0]    pipe_rounding_mode;
    wire                    pipe_valid_out;
    wire                    pipe_ready_in;
    wire [7:0]              pipe_result;
    wire [`FLAG_WIDTH-1:0]  pipe_flags;
    wire [`EXC_WIDTH-1:0]   pipe_exceptions;

    fp8_controller #(
        .RD_FIFO_DEPTH(RD_FIFO_DEPTH)
    ) u_ctrl (
        .clk              (clk),
        .rst              (rst),
        .issue_valid      (issue_valid),
        .issue_ready      (issue_ready),
        .issue_A          (issue_A),
        .issue_B          (issue_B),
        .issue_opcode     (issue_opcode),
        .issue_rm         (issue_rm),
        .issue_rd         (issue_rd),
        .wb_valid         (wb_valid),
        .wb_ready         (wb_ready),
        .wb_result        (wb_result),
        .wb_flags         (wb_flags),
        .wb_exceptions    (wb_exceptions),
        .wb_rd            (wb_rd),
        .fpu_busy         (fpu_busy),
        .flush            (flush),
        .pipe_valid_in    (pipe_valid_in),
        .pipe_ready_out   (pipe_ready_out),
        .pipe_A           (pipe_A),
        .pipe_B           (pipe_B),
        .pipe_opcode      (pipe_opcode),
        .pipe_rounding_mode(pipe_rounding_mode),
        .pipe_valid_out   (pipe_valid_out),
        .pipe_ready_in    (pipe_ready_in),
        .pipe_result      (pipe_result),
        .pipe_flags       (pipe_flags),
        .pipe_exceptions  (pipe_exceptions)
    );

    fp8_elastic_pipeline u_pipe (
        .clk          (clk),
        .rst          (rst),
        .flush        (flush),
        .valid_in     (pipe_valid_in),
        .ready_out    (pipe_ready_out),
        .A            (pipe_A),
        .B            (pipe_B),
        .opcode       (pipe_opcode),
        .rounding_mode(pipe_rounding_mode),
        .valid_out    (pipe_valid_out),
        .ready_in     (pipe_ready_in),
        .result       (pipe_result),
        .flags        (pipe_flags),
        .exceptions   (pipe_exceptions)
    );

endmodule
