// ======================================================================
// tb_fp8_controller.v
//
// Teste do fp8_controller ISOLADO da aritmetica. A pipeline real e'
// substituida por um STUB comportamental (pipe_stub) — uma FIFO elastica
// in-order que devolve `A` como "resultado" (flags = A[6:0], exc = A[4:0]).
// Assim o scoreboard preve a saida so a partir da entrada, e o foco fica
// 100% na logica do controller: FIFO de rd, casamento rd<->resultado,
// handshake de writeback, flush e FIFO cheia.
//
// Estimulo: cada operacao k usa A=k, rd=k%32 (5b), opcode=k%4, rm=k%8.
// Como tudo e' in-order, o j-esimo writeback tem que ter:
//   wb_result = j&0xFF,  wb_rd = j%32,  wb_flags = j[6:0],  wb_exc = j[4:0]
//
// FASES:
//   1) Stream com bolhas (issue) + back-pressure de writeback (wb_ready)
//   2) FIFO cheia: wb_ready=0 e issue continuo -> issue_ready deve cair;
//      depois drena e confere que NADA se perdeu
//   3) Flush mid-stream: acumula em voo, da flush, e confere que o pipe
//      esvazia (fpu_busy=0), NAO vaza writeback, e se recupera limpo
//
// RODAR (ModelSim/Questa):
//   vlog header_fp8.v fp8_controller.v tb_fp8_controller.v
//   vsim -c tb_fp8_controller -do "run -all; quit"
// Icarus:
//   iverilog -g2012 -o sim header_fp8.v fp8_controller.v tb_fp8_controller.v && vvp sim
// ======================================================================
`include "../src/header_fp8.v"
`timescale 1ns/1ps

module tb_fp8_controller;

    localparam integer RD_DEPTH = 8;    // profundidade da FIFO de rd no controller

    reg                    clk = 1'b0;
    reg                    rst, flush;

    // issue (core -> ctrl)
    reg                    issue_valid;
    wire                   issue_ready;
    reg  [7:0]             issue_A, issue_B;
    reg  [`OP_WIDTH-1:0]   issue_opcode;
    reg  [2:0]             issue_rm;
    reg  [4:0]             issue_rd;

    // writeback (ctrl -> core)
    wire                   wb_valid;
    reg                    wb_ready;
    wire [7:0]             wb_result;
    wire [`FLAG_WIDTH-1:0] wb_flags;
    wire [`EXC_WIDTH-1:0]  wb_exceptions;
    wire [4:0]             wb_rd;

    wire                   fpu_busy;

    // ctrl <-> pipe (stub)
    wire                   pipe_valid_in, pipe_ready_out;
    wire [7:0]             pipe_A, pipe_B;
    wire [`OP_WIDTH-1:0]   pipe_opcode;
    wire [`RD_WIDTH-1:0]   pipe_rounding_mode;
    wire                   pipe_valid_out, pipe_ready_in;
    wire [7:0]             pipe_result;
    wire [`FLAG_WIDTH-1:0] pipe_flags;
    wire [`EXC_WIDTH-1:0]  pipe_exceptions;

    fp8_controller #(.RD_FIFO_DEPTH(RD_DEPTH)) dut (
        .clk(clk), .rst(rst),
        .issue_valid(issue_valid), .issue_ready(issue_ready),
        .issue_A(issue_A), .issue_B(issue_B),
        .issue_opcode(issue_opcode), .issue_rm(issue_rm), .issue_rd(issue_rd),
        .wb_valid(wb_valid), .wb_ready(wb_ready),
        .wb_result(wb_result), .wb_flags(wb_flags),
        .wb_exceptions(wb_exceptions), .wb_rd(wb_rd),
        .fpu_busy(fpu_busy), .flush(flush),
        .pipe_valid_in(pipe_valid_in), .pipe_ready_out(pipe_ready_out),
        .pipe_A(pipe_A), .pipe_B(pipe_B),
        .pipe_opcode(pipe_opcode), .pipe_rounding_mode(pipe_rounding_mode),
        .pipe_valid_out(pipe_valid_out), .pipe_ready_in(pipe_ready_in),
        .pipe_result(pipe_result), .pipe_flags(pipe_flags),
        .pipe_exceptions(pipe_exceptions)
    );

    // STUB de pipeline (profundidade folgada p/ a FIFO de rd ser o gargalo)
    pipe_stub #(.DEPTH(16)) u_stub (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(pipe_valid_in), .ready_out(pipe_ready_out),
        .A(pipe_A), .B(pipe_B),
        .opcode(pipe_opcode), .rounding_mode(pipe_rounding_mode),
        .valid_out(pipe_valid_out), .ready_in(pipe_ready_in),
        .result(pipe_result), .flags(pipe_flags), .exceptions(pipe_exceptions)
    );

    always #5 clk = ~clk;

    // ---- scoreboard ----
    integer i_issue;     // proximo indice a emitir
    integer exp_idx;     // proximo indice esperado no writeback
    integer pass_cnt, err_cnt, printed;
    integer max_out;     // maximo de operacoes em voo observado
    integer leak_cnt;
    integer s, k;
    integer total_err;
    integer NTOTAL;      // limite logico de emissao na fase atual
    reg     ir_stuck;    // issue_ready caiu durante FIFO cheia? (capturado no instante certo)
    reg     busy_bad;    // fpu_busy ficou alto apos drenar?

    // checa um writeback contra o esperado para exp_idx
    task check_wb;
        reg [7:0] e_res, e_fl, e_ex;
        reg [4:0] e_rd;
        begin
            e_res = exp_idx[7:0];
            e_rd  = exp_idx % 32;
            e_fl  = exp_idx[6:0];
            e_ex  = exp_idx[4:0];
            if (wb_result===e_res && wb_rd===e_rd &&
                wb_flags===e_fl[`FLAG_WIDTH-1:0] && wb_exceptions===e_ex[`EXC_WIDTH-1:0]) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                err_cnt = err_cnt + 1;
                if (printed < 30) begin
                    printed = printed + 1;
                    $display("  [FAIL] wb #%0d: result got=%02h exp=%02h | rd got=%0d exp=%0d | flags got=%07b exp=%07b | exc got=%05b exp=%05b",
                        exp_idx, wb_result, e_res, wb_rd, e_rd,
                        wb_flags, e_fl[`FLAG_WIDTH-1:0],
                        wb_exceptions, e_ex[`EXC_WIDTH-1:0]);
                end
            end
            exp_idx = exp_idx + 1;
        end
    endtask

    // um passo: dirige issue (iv) e wb_ready (wr); confere writeback; avanca
    task step;
        input iv;
        input wr;
        begin
            @(negedge clk);
            issue_valid  = iv & (i_issue < NTOTAL);
            issue_A      = i_issue[7:0];
            issue_B      = ~i_issue[7:0];
            issue_opcode = i_issue[1:0];
            issue_rm     = i_issue[2:0];
            issue_rd     = i_issue % 32;
            wb_ready     = wr;

            @(posedge clk);   // DUT atualiza; leituras abaixo sao PRE-edge

            if (wb_valid && wb_ready) check_wb;

            if ((i_issue - exp_idx) > max_out) max_out = (i_issue - exp_idx);

            if (issue_valid && issue_ready && i_issue < NTOTAL)
                i_issue = i_issue + 1;
        end
    endtask

    task do_reset;
        begin
            rst=1; flush=0;
            issue_valid=0; issue_A=0; issue_B=0; issue_opcode=0; issue_rm=0; issue_rd=0;
            wb_ready=1;
            i_issue=0; exp_idx=0; max_out=0;
            repeat(3) @(posedge clk);
            @(negedge clk) rst=0;
        end
    endtask

    initial begin
        pass_cnt=0; err_cnt=0; printed=0; total_err=0;

        $display("======================================================");
        $display(" TB fp8_controller (pipeline = stub comportamental)");
        $display("======================================================");

        // ---------- FASE 1: stream + bolhas + back-pressure wb ----------
        $display("\n--- Fase 1: stream (bolhas + back-pressure de writeback) ---");
        do_reset;
        NTOTAL = 2000;
        k = 0;
        while (exp_idx < NTOTAL && k < 200000) begin
            step((({$random} % 100) < 70), (({$random} % 100) < 70));
            k = k + 1;
        end
        repeat (3) @(posedge clk);   // deixa o ultimo wb assentar
        busy_bad = (fpu_busy !== 1'b0);
        if (busy_bad)
            $display("  [WARN] fpu_busy=%b apos drenar tudo (deveria ser 0)", fpu_busy);
        $display("  drenou %0d/%0d  | max em voo=%0d | pass=%0d err=%0d",
                 exp_idx, NTOTAL, max_out, pass_cnt, err_cnt);
        total_err = total_err + err_cnt + (busy_bad ? 1 : 0);

        // ---------- FASE 2: FIFO cheia ----------
        $display("\n--- Fase 2: FIFO de rd cheia (wb travado) ---");
        do_reset;
        err_cnt=0; printed=0;
        NTOTAL = 1000;
        // wb travado: oferece issue continuo e observa issue_ready cair
        for (k = 0; k < 40; k = k + 1)
            step(1'b1, 1'b0);                 // wb_ready=0
        // captura issue_ready AGORA, com a FIFO cheia (antes de drenar)
        ir_stuck = (issue_ready !== 1'b0);
        $display("  com wb travado: aceitos=%0d  max em voo=%0d  issue_ready=%b (deve estar 0)",
                 i_issue, max_out, issue_ready);
        if (ir_stuck)
            $display("  [FAIL] issue_ready nao caiu com FIFO cheia");
        // libera writeback e drena tudo que foi aceito
        while (exp_idx < i_issue && k < 200000) begin
            step(1'b1, (({$random} % 100) < 70));
            k = k + 1;
        end
        $display("  drenou %0d aceitos | pass=%0d err=%0d", exp_idx, pass_cnt, err_cnt);
        if (max_out > RD_DEPTH + 1)
            $display("  [FAIL] em voo=%0d excedeu a capacidade da FIFO (%0d)", max_out, RD_DEPTH);
        total_err = total_err + err_cnt + (ir_stuck ? 1 : 0)
                                + ((max_out > RD_DEPTH + 1) ? 1 : 0);

        // ---------- FASE 3: flush mid-stream ----------
        $display("\n--- Fase 3: flush mid-stream ---");
        do_reset;
        err_cnt=0; printed=0; leak_cnt=0;
        NTOTAL = 1000;
        // acumula operacoes em voo SEM writeback (wb_ready=0)
        for (k = 0; k < 6; k = k + 1)
            step(1'b1, 1'b0);
        $display("  antes do flush: em voo=%0d  fpu_busy=%b", i_issue - exp_idx, fpu_busy);
        // pulso de flush
        @(negedge clk); flush=1; issue_valid=0; wb_ready=1;
        @(posedge clk);
        @(negedge clk) flush=0;
        @(posedge clk);
        // pos-flush: pipe deve estar vazio e nao pode vazar writeback
        if (fpu_busy !== 1'b0) begin
            $display("  [FAIL] fpu_busy=%b apos flush (deveria ser 0)", fpu_busy);
            total_err = total_err + 1;
        end else
            $display("  [OK] fpu_busy=0 apos flush");
        for (k = 0; k < 20; k = k + 1) begin
            @(negedge clk); issue_valid=0; wb_ready=1;
            @(posedge clk);
            if (wb_valid) leak_cnt = leak_cnt + 1;
        end
        if (leak_cnt != 0) begin
            $display("  [FAIL] vazaram %0d writebacks de operacoes 'flushadas'", leak_cnt);
            total_err = total_err + 1;
        end else
            $display("  [OK] nenhum writeback vazou apos flush");

        // recuperacao: stream fresco do zero, tem que casar certinho
        i_issue=0; exp_idx=0; max_out=0; err_cnt=0; printed=0;
        NTOTAL = 500;
        k = 0;
        while (exp_idx < NTOTAL && k < 200000) begin
            step((({$random} % 100) < 80), (({$random} % 100) < 80));
            k = k + 1;
        end
        $display("  recuperacao pos-flush: drenou %0d/%0d  pass_total=%0d err=%0d",
                 exp_idx, NTOTAL, pass_cnt, err_cnt);
        total_err = total_err + err_cnt;

        // ---------- veredito ----------
        $display("\n======================================================");
        if (total_err == 0)
            $display(" RESULTADO: PASS  (0 erros) -- controller OK");
        else
            $display(" RESULTADO: FAIL  (%0d erros)", total_err);
        $display(" total writebacks conferidos OK: %0d", pass_cnt);
        $display("======================================================");
        $finish;
    end

    initial begin
        #50000000;
        $display("TIMEOUT global: i_issue=%0d exp_idx=%0d", i_issue, exp_idx);
        $finish;
    end

endmodule


// ======================================================================
// pipe_stub — modelo elastico in-order do "pipeline", para isolar o
// controller. FIFO simples: guarda A; devolve result=A, flags=A[6:0],
// exc=A[4:0]. Latencia minima 1; respeita valid/ready e flush.
// ======================================================================
`include "../src/header_fp8.v"

module pipe_stub #(
    parameter integer DEPTH = 16
) (
    input  wire                    clk, rst, flush,
    input  wire                    valid_in,
    output wire                    ready_out,
    input  wire [7:0]              A, B,
    input  wire [`OP_WIDTH-1:0]    opcode,
    input  wire [`RD_WIDTH-1:0]    rounding_mode,
    output wire                    valid_out,
    input  wire                    ready_in,
    output wire [7:0]              result,
    output wire [`FLAG_WIDTH-1:0]  flags,
    output wire [`EXC_WIDTH-1:0]   exceptions
);
    localparam integer AW = $clog2(DEPTH);

    reg [7:0]      mem [0:DEPTH-1];
    reg [AW:0]     head, tail;

    wire full  = (head[AW-1:0] == tail[AW-1:0]) && (head[AW] != tail[AW]);
    wire empty = (head == tail);

    assign ready_out  = !full;
    assign valid_out  = !empty;
    assign result     = mem[tail[AW-1:0]];
    assign flags      = result[`FLAG_WIDTH-1:0];
    assign exceptions = result[`EXC_WIDTH-1:0];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            head <= 0; tail <= 0;
        end else if (flush) begin
            head <= 0; tail <= 0;
        end else begin
            if (valid_in && ready_out) begin
                mem[head[AW-1:0]] <= A;
                head <= head + 1'b1;
            end
            if (valid_out && ready_in) begin
                tail <= tail + 1'b1;
            end
        end
    end
endmodule
