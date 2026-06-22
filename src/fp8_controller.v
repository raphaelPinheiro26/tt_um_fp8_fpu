// ======================================================================
// fp8_controller.v
// Controlador da FPU FP8 E4M3: gerencia issue/writeback e FIFO de rd.
//
// Baseado diretamente no fp4_controller, adaptado para 8 bits.
// Responsabilidades:
//   - Recebe operações do core (issue_valid/ready)
//   - Armazena rd numa FIFO circular (até RD_FIFO_DEPTH entradas)
//   - Encaminha a operação para a pipeline
//   - Recebe resultado da pipeline e faz writeback ao core
// ======================================================================
`include "header_fp8.v"

module fp8_controller #(
    parameter RD_FIFO_DEPTH = 8
) (
    input  wire                    clk,
    input  wire                    rst,

    // Interface issue (do core)
    input  wire                    issue_valid,
    output wire                    issue_ready,
    input  wire [7:0]              issue_A,
    input  wire [7:0]              issue_B,
    input  wire [`OP_WIDTH-1:0]    issue_opcode,
    input  wire [2:0]              issue_rm,
    input  wire [4:0]              issue_rd,

    // Interface writeback (para o core)
    output reg                     wb_valid,
    input  wire                    wb_ready,
    output reg  [7:0]              wb_result,
    output reg  [`FLAG_WIDTH-1:0]  wb_flags,
    output reg  [`EXC_WIDTH-1:0]   wb_exceptions,
    output reg  [4:0]              wb_rd,

    // Sinal de ocupado
    output wire                    fpu_busy,

    // Flush da pipeline
    input  wire                    flush,

    // Interface com a pipeline
    output wire                    pipe_valid_in,
    input  wire                    pipe_ready_out,
    output wire [7:0]              pipe_A,
    output wire [7:0]              pipe_B,
    output wire [`OP_WIDTH-1:0]    pipe_opcode,
    output wire [`RD_WIDTH-1:0]    pipe_rounding_mode,
    input  wire                    pipe_valid_out,
    output wire                    pipe_ready_in,
    input  wire [7:0]              pipe_result,
    input  wire [`FLAG_WIDTH-1:0]  pipe_flags,
    input  wire [`EXC_WIDTH-1:0]   pipe_exceptions
);

    // ──────────────────────────────────────────────────────────────────────
    // FIFO circular para rastreamento de rd
    // ──────────────────────────────────────────────────────────────────────
    localparam FIFO_AW = $clog2(RD_FIFO_DEPTH);

    reg [4:0]       rd_fifo [0:RD_FIFO_DEPTH-1];
    reg [FIFO_AW:0] fifo_head;
    reg [FIFO_AW:0] fifo_tail;

    wire fifo_full  = ((fifo_tail[FIFO_AW-1:0] == fifo_head[FIFO_AW-1:0]) &&
                       (fifo_tail[FIFO_AW] != fifo_head[FIFO_AW]));
    wire fifo_empty = (fifo_tail == fifo_head);

    // Issue aceito se pipeline aceita e FIFO não está cheia
    assign issue_ready   = pipe_ready_out && !fifo_full;
    assign pipe_valid_in = issue_valid && !fifo_full;

    // Encaminha operandos diretamente para a pipeline
    assign pipe_A              = issue_A;
    assign pipe_B              = issue_B;
    assign pipe_opcode         = issue_opcode;
    assign pipe_rounding_mode  = {1'b0, issue_rm};

    // Pipeline aceita resultado quando não há writeback pendente ou wb_ready
    assign pipe_ready_in = !wb_valid || wb_ready;

    assign fpu_busy = !fifo_empty || wb_valid;

    integer i;

    always @(posedge clk or posedge rst) begin
		  i = 0; 
        if (rst) begin
            fifo_head <= {(FIFO_AW+1){1'b0}};
            fifo_tail <= {(FIFO_AW+1){1'b0}};
            wb_valid  <= 1'b0;
            wb_result <= 8'h00;
            wb_flags  <= 7'b0;
            wb_exceptions <= 5'b0;
            wb_rd     <= 5'b0;
            for (i = 0; i < RD_FIFO_DEPTH; i = i + 1)
                rd_fifo[i] <= 5'b0;
        end else if (flush) begin
            fifo_head <= fifo_tail;
            wb_valid  <= 1'b0;
        end else begin
            // ----------------------------------------------------------
            // Issue: empilha rd na FIFO
            // ----------------------------------------------------------
            if (issue_valid && issue_ready) begin
                rd_fifo[fifo_head[FIFO_AW-1:0]] <= issue_rd;
                fifo_head <= fifo_head + 1'b1;
            end

            // ----------------------------------------------------------
            // Writeback: consome resultado da pipeline
            // ----------------------------------------------------------
            if (wb_valid && wb_ready)
                wb_valid <= 1'b0;

            if (pipe_valid_out && pipe_ready_in && !fifo_empty) begin
                wb_valid      <= 1'b1;
                wb_result     <= pipe_result;
                wb_flags      <= pipe_flags;
                wb_exceptions <= pipe_exceptions;
                wb_rd         <= rd_fifo[fifo_tail[FIFO_AW-1:0]];
                fifo_tail     <= fifo_tail + 1'b1;
            end
        end
    end

endmodule
