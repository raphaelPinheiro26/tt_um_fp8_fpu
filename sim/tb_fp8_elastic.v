// ======================================================================
// tb_fp8_elastic.v — Testbench para fp8_elastic_pipeline (FP8 E4M3)
//
// Latência da pipeline: 3 ciclos de clock.
// O testbench envia uma operação por vez e aguarda valid_out=1.
// ======================================================================
`include "../src/header_fp8.v"
`timescale 1ns/1ps

module tb_fp8_elastic;

    reg         clk, rst, flush;
    reg         valid_in, ready_in;
    reg  [7:0]  A, B;
    reg  [4:0]  opcode;
    reg  [3:0]  rounding_mode;
    wire        ready_out, valid_out;
    wire [7:0]  result;
    wire [`FLAG_WIDTH-1:0] flags;
    wire [`EXC_WIDTH-1:0]  exceptions;

    integer pass_cnt = 0, fail_cnt = 0;

    fp8_elastic_pipeline dut (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(valid_in), .ready_out(ready_out),
        .A(A), .B(B), .opcode(opcode), .rounding_mode(rounding_mode),
        .valid_out(valid_out), .ready_in(ready_in),
        .result(result), .flags(flags), .exceptions(exceptions)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // FP8 E4M3 → real
    function real fp8_to_real;
        input [7:0] fp;
        reg [3:0] e; reg [2:0] m; reg s; real v;
        begin
            s = fp[7]; e = fp[6:3]; m = fp[2:0];
            if (e == 4'hF) v = (m == 0) ? 1.0e30 : 0.0;       // Inf/NaN placeholder
            else if (e == 4'h0) v = m * (1.0/512.0);            // subnormal: m × 2^(-9)
            else v = (1.0 + m/8.0) * (2.0**($signed({1'b0,e})-7));
            fp8_to_real = s ? -v : v;
        end
    endfunction

    // Envia op e aguarda resultado
    task run_op;
        input [7:0]  iA, iB;
        input [4:0]  opc;
        input [7:0]  expected;
        input [8*12-1:0] label;
        reg   [7:0]  got;
        integer timeout;
        begin
            @(negedge clk);
            A = iA; B = iB; opcode = opc;
            rounding_mode = {1'b0, `ROUND_NEAREST};
            valid_in = 1'b1;
            @(negedge clk);
            valid_in = 1'b0;
            // Aguarda valid_out com timeout
            timeout = 0;
            ready_in = 1'b1;
            @(posedge clk);
            while (!valid_out && timeout < 20) begin
                @(posedge clk); timeout = timeout + 1;
            end
            got = result;
            if (got === expected) begin
                pass_cnt = pass_cnt + 1;
                $display("PASS [%0s] A=%h B=%h => %h  flags=%b exc=%b",
                    label, iA, iB, got, flags, exceptions);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("FAIL [%0s] A=%h(%.4f) B=%h(%.4f) => got=%h exp=%h  flags=%b exc=%b",
                    label, iA, fp8_to_real(iA), iB, fp8_to_real(iB),
                    got, expected, flags, exceptions);
            end
        end
    endtask

    // ── Constantes FP8 E4M3 ───────────────────────────────────────────
    // +1.0  = {0,0111,000} = 8'h38    +2.0  = {0,1000,000} = 8'h40
    // +3.0  = {0,1000,100} = 8'h44    +4.0  = {0,1001,000} = 8'h48
    // +0.5  = {0,0110,000} = 8'h30    +1.5  = {0,0111,100} = 8'h3C
    // +0.25 = {0,0101,000} = 8'h28    +0.75 = {0,0110,100} = 8'h34
    // -1.0  = {1,0111,000} = 8'hB8    -2.0  = {1,1000,000} = 8'hC0
    // +Inf  = {0,1111,000} = 8'h78    -Inf  = {1,1111,000} = 8'hF8
    // +NaN  = {0,1111,001} = 8'h79    +0    = 8'h00
    // sub1  = {0,0000,001} = 8'h01

    localparam ONE    = 8'h38, TWO    = 8'h40, THREE  = 8'h44, FOUR  = 8'h48;
    localparam HALF   = 8'h30, ONEH   = 8'h3C, QRTR   = 8'h28, THRQT= 8'h34;
    localparam NEG1   = 8'hB8, NEG2   = 8'hC0;
    localparam PINF   = 8'h78, NINF   = 8'hF8, NAN    = 8'h79;
    localparam PZERO  = 8'h00, NZERO  = 8'h80, SUB1   = 8'h01;

    initial begin
        $display("=== FPU FP8 E4M3 — Testbench ===");
        flush=0; valid_in=0; ready_in=1;
        A=0; B=0; opcode=0; rounding_mode=0;
        rst=1; repeat(3) @(posedge clk); rst=0; @(posedge clk);

        $display("\n--- ADD ---");
        run_op(ONE,  ONE,  `OPCODE_ADD, TWO,  "1.0+1.0 ");   // 2.0
        run_op(ONE,  HALF, `OPCODE_ADD, ONEH, "1.0+0.5 ");   // 1.5
        run_op(TWO,  TWO,  `OPCODE_ADD, FOUR, "2.0+2.0 ");   // 4.0
        run_op(HALF, HALF, `OPCODE_ADD, ONE,  "0.5+0.5 ");   // 1.0
        run_op(ONE,  NEG1, `OPCODE_ADD, PZERO,"1.0+-1.0");   // 0
        run_op(QRTR, QRTR, `OPCODE_ADD, HALF, "0.25+0.25");  // 0.5

        $display("\n--- SUB ---");
        run_op(TWO,  ONE,  `OPCODE_SUB, ONE,  "2.0-1.0 ");   // 1.0
        run_op(ONEH, HALF, `OPCODE_SUB, ONE,  "1.5-0.5 ");   // 1.0
        run_op(ONE,  ONE,  `OPCODE_SUB, PZERO,"1.0-1.0 ");   // 0
        run_op(TWO,  ONEH, `OPCODE_SUB, HALF, "2.0-1.5 ");   // 0.5
        run_op(NEG1, NEG1, `OPCODE_SUB, PZERO,"-1-(-1) ");   // 0

        $display("\n--- MULT ---");
        run_op(ONE,  ONE,  `OPCODE_MULT, ONE,  "1.0x1.0 ");   // 1.0
        run_op(TWO,  TWO,  `OPCODE_MULT, FOUR, "2.0x2.0 ");   // 4.0
        run_op(ONE,  HALF, `OPCODE_MULT, HALF, "1.0x0.5 ");   // 0.5
        run_op(TWO,  HALF, `OPCODE_MULT, ONE,  "2.0x0.5 ");   // 1.0
        run_op(ONE,  NEG1, `OPCODE_MULT, NEG1, "1.0x-1.0");   // -1.0
        run_op(NEG1, NEG1, `OPCODE_MULT, ONE,  "-1x-1   ");   // 1.0

        $display("\n--- DIV ---");
        run_op(ONE,  ONE,  `OPCODE_DIV, ONE,  "1.0/1.0 ");   // 1.0
        run_op(FOUR, TWO,  `OPCODE_DIV, TWO,  "4.0/2.0 ");   // 2.0
        run_op(ONE,  TWO,  `OPCODE_DIV, HALF, "1.0/2.0 ");   // 0.5
        run_op(THREE,ONE,  `OPCODE_DIV, THREE,"3.0/1.0 ");   // 3.0
        run_op(TWO,  FOUR, `OPCODE_DIV, HALF, "2.0/4.0 ");   // 0.5
        run_op(ONE,  FOUR, `OPCODE_DIV, QRTR, "1.0/4.0 ");   // 0.25

        $display("\n--- Casos Especiais ---");
        run_op(NAN,  ONE,  `OPCODE_ADD,  NAN,  "NaN+1.0 ");
        run_op(ONE,  NAN,  `OPCODE_ADD,  NAN,  "1.0+NaN ");
        run_op(PINF, ONE,  `OPCODE_ADD,  PINF, "Inf+1.0 ");
        run_op(PINF, PINF, `OPCODE_SUB,  NAN,  "Inf-Inf ");
        run_op(PINF, PINF, `OPCODE_ADD,  PINF, "Inf+Inf ");
        run_op(PINF, NINF, `OPCODE_ADD,  NAN,  "Inf+-Inf");
        run_op(PZERO,PZERO,`OPCODE_DIV,  NAN,  "0/0     ");
        run_op(ONE,  PZERO,`OPCODE_DIV,  PINF, "1/0     ");
        run_op(PZERO,ONE,  `OPCODE_DIV,  PZERO,"0/1     ");
        run_op(PINF, PZERO,`OPCODE_MULT, NAN,  "Inf*0   ");
        run_op(PINF, TWO,  `OPCODE_MULT, PINF, "Inf*2   ");
        run_op(SUB1, PZERO,`OPCODE_ADD,  SUB1, "sub+0   ");
        run_op(PZERO,PZERO,`OPCODE_ADD,  PZERO,"0+0     ");

        repeat(4) @(posedge clk);
        $display("\n=== Resultado: %0d PASS / %0d FAIL ===", pass_cnt, fail_cnt);
        $finish;
    end

    initial begin #100000; $display("TIMEOUT"); $finish; end
endmodule
