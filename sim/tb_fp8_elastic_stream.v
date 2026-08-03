// ======================================================================
// tb_fp8_elastic_stream.v
//
// Teste PONTA-A-PONTA da fp8_elastic_pipeline sob BACK-PRESSURE.
//
// Le vectors.hex (mesmo formato do tb_fp8_golden):
//     A B opcode rm  res_golden flags_golden exc_golden   (tudo em hex)
// e dirige a pipeline com:
//   - valid_in pseudo-aleatorio  (bolhas na entrada)
//   - ready_in pseudo-aleatorio  (back-pressure na saida)
// respeitando o handshake nos DOIS lados:
//   - so avanca o vetor de entrada quando valid_in && ready_out
//   - so captura a saida quando valid_out && ready_in
//
// A pipeline e' in-order, entao um scoreboard em ordem compara
// result + flags + exceptions de cada saida contra o vetor i_recv.
// Isso exercita o caminho elastico (skid buffers) que o tb_fp8_golden,
// com ready_in fixo em 1, nunca testa.
//
// PLUSARGS:
//   +vecfile=<caminho>   caminho do vectors.hex (override)
//   +maxvec=<N>          usa so os primeiros N vetores (smoke test)
//   +maxfail=<N>         para de imprimir apos N falhas (default 30)
//   +pvalid=<0..100>     prob. de valid_in por ciclo (default 70)
//   +pready=<0..100>     prob. de ready_in por ciclo (default 70)
//   +stop_on_fail        aborta na primeira falha
//
// RODAR (ModelSim/Questa), da pasta com o vectors.hex:
//   vlog header_fp8.v fp8_unpack.v fp8_pre_execute.v fp8_execute_comb.v \
//        fp8_normalize.v fp8_round.v fp8_handshake_reg.v \
//        fp8_elastic_pipeline.v tb_fp8_elastic_stream.v
//   vsim -c tb_fp8_elastic_stream -do "run -all; quit"
//   # smoke rapido:
//   vsim -c tb_fp8_elastic_stream +maxvec=5000 -do "run -all; quit"
// ======================================================================
`include "../src/header_fp8.v"
`timescale 1ns/1ps

module tb_fp8_elastic_stream;

    localparam integer MAXV = 2000000;

    reg         clk, rst, flush;
    reg         valid_in, ready_in;
    reg  [7:0]  A, B;
    reg  [4:0]  opcode;
    reg  [3:0]  rounding_mode;
    wire        ready_out, valid_out;
    wire [7:0]  result;
    wire [`FLAG_WIDTH-1:0] flags;
    wire [`EXC_WIDTH-1:0]  exceptions;

    fp8_elastic_pipeline dut (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(valid_in), .ready_out(ready_out),
        .A(A), .B(B), .opcode(opcode), .rounding_mode(rounding_mode),
        .valid_out(valid_out), .ready_in(ready_in),
        .result(result), .flags(flags), .exceptions(exceptions)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // ---- memorias de vetores ----------------------------------------
    reg [7:0]  vA   [0:MAXV-1];
    reg [7:0]  vB   [0:MAXV-1];
    reg [3:0]  vOp  [0:MAXV-1];
    reg [3:0]  vRm  [0:MAXV-1];
    reg [7:0]  vRes [0:MAXV-1];
    reg [7:0]  vFl  [0:MAXV-1];
    reg [7:0]  vEx  [0:MAXV-1];

    integer NVEC;
    integer fd, code;
    reg [4095:0] vecpath, tbpath, rootdir;
    reg [7:0] ta, tb_, tres, tfl, tex;
    reg [3:0] top, trm;

    integer i_send, i_recv;
    integer pass_cnt, fail_cnt, printed;
    integer maxfail, maxvec;
    integer pvalid, pready;
    reg     stop_on_fail;

    // stall watchdog
    integer last_recv, stall_cyc;

    // ---- helpers de caminho portavel (iguais ao tb_fp8_golden) -------
    function integer str_len;
        input [4095:0] s;
        integer i, started, n; reg [7:0] c;
        begin
            n = 0; started = 0;
            for (i = 4095; i >= 7; i = i - 8) begin
                c = s[i -: 8];
                if (c != 8'h00) started = 1;
                if (started) n = n + 1;
            end
            str_len = n;
        end
    endfunction

    function [4095:0] dirname_of;
        input [4095:0] s;
        integer len, cutpos, idx; reg [7:0] c; reg [4095:0] out;
        begin
            len = str_len(s); cutpos = -1;
            for (idx = 0; idx < len; idx = idx + 1) begin
                c = s[(len-idx)*8-1 -: 8];
                if (c == "/" || c == 8'h5C) cutpos = idx;
            end
            out = 0;
            if (cutpos < 0) out = ".";
            else for (idx = 0; idx < cutpos; idx = idx + 1) begin
                c = s[(len-idx)*8-1 -: 8];
                out = (out << 8) | c;
            end
            dirname_of = out;
        end
    endfunction

    function [4095:0] pjoin;
        input [4095:0] dir; input [4095:0] name;
        integer i, dl, nl; reg [7:0] c; reg [4095:0] out;
        begin
            dl = str_len(dir); nl = str_len(name); out = 0;
            for (i = 0; i < dl; i = i + 1) begin
                c = dir[(dl-i)*8-1 -: 8]; out = (out << 8) | c;
            end
            out = (out << 8) | "/";
            for (i = 0; i < nl; i = i + 1) begin
                c = name[(nl-i)*8-1 -: 8]; out = (out << 8) | c;
            end
            pjoin = out;
        end
    endfunction

    // ---- comparacao de uma saida contra o vetor esperado --------------
    task check_output;
        input integer idx;
        input [7:0] got_res;
        input [`FLAG_WIDTH-1:0] got_fl;
        input [`EXC_WIDTH-1:0] got_ex;
        reg res_ok, fl_ok, ex_ok;
        reg [7:0] e_res, e_fl, e_ex;
        begin
            e_res = vRes[idx]; e_fl = vFl[idx]; e_ex = vEx[idx];
            res_ok = (got_res === e_res);
            fl_ok  = (got_fl  === e_fl[`FLAG_WIDTH-1:0]);
            ex_ok  = (got_ex  === e_ex[`EXC_WIDTH-1:0]);
            if (res_ok && fl_ok && ex_ok) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                if (printed < maxfail) begin
                    printed = printed + 1;
                    $display("FAIL #%0d A=%02h B=%02h op=%0d rm=%0d | res got=%02h exp=%02h %s | flags got=%07b exp=%07b %s | exc got=%05b exp=%05b %s",
                        idx, vA[idx], vB[idx], vOp[idx], vRm[idx],
                        got_res, e_res, res_ok?"":"<<",
                        got_fl,  e_fl[`FLAG_WIDTH-1:0], fl_ok?"":"<<",
                        got_ex,  e_ex[`EXC_WIDTH-1:0], ex_ok?"":"<<");
                end
                if (stop_on_fail) begin
                    $display("=== abortando na primeira falha (+stop_on_fail) ===");
                    $finish;
                end
            end
        end
    endtask

    // ==================================================================
    // Setup: plusargs, carga de vetores, reset
    // ==================================================================
    initial begin
        maxfail = 30; stop_on_fail = 1'b0; maxvec = 0;
        pvalid = 70; pready = 70;
        if ($value$plusargs("maxfail=%d", maxfail)) ;
        if ($value$plusargs("maxvec=%d",  maxvec))  ;
        if ($value$plusargs("pvalid=%d",  pvalid))  ;
        if ($value$plusargs("pready=%d",  pready))  ;
        if ($test$plusargs("stop_on_fail")) stop_on_fail = 1'b1;

        // resolucao do caminho do vectors.hex
        NVEC = 0; fd = 0;
        if ($value$plusargs("vecfile=%s", vecpath))
            fd = $fopen(vecpath, "r");
        if (fd == 0) begin
            vecpath = "../Golden_model/vectors.hex";
            fd = $fopen(vecpath, "r");
        end
        if (fd == 0) begin
            tbpath  = `__FILE__;
            rootdir = dirname_of(dirname_of(tbpath));
            vecpath = pjoin(rootdir, "Golden_model/vectors.hex");
            fd = $fopen(vecpath, "r");
        end
        if (fd == 0) begin
            $display("ERRO: nao consegui abrir vectors.hex.");
            $display("  aponte com: vsim ... +vecfile=C:/caminho/vectors.hex");
            $finish;
        end
        $display(">> lendo vetores de: %0s", vecpath);

        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h %h %h %h %h %h\n",
                           ta, tb_, top, trm, tres, tfl, tex);
            if (code == 7) begin
                vA[NVEC]=ta; vB[NVEC]=tb_; vOp[NVEC]=top; vRm[NVEC]=trm;
                vRes[NVEC]=tres; vFl[NVEC]=tfl; vEx[NVEC]=tex;
                NVEC = NVEC + 1;
            end
        end
        $fclose(fd);
        if (maxvec > 0 && maxvec < NVEC) NVEC = maxvec;
        $display("=== %0d vetores | back-pressure: pvalid=%0d%% pready=%0d%% ===",
                 NVEC, pvalid, pready);

        // reset
        flush=0; valid_in=0; ready_in=1; A=0; B=0; opcode=0; rounding_mode=0;
        rst=1; repeat(3) @(posedge clk); rst=0; @(posedge clk);

        pass_cnt=0; fail_cnt=0; printed=0;
        i_send=0; i_recv=0;
        last_recv=0; stall_cyc=0;
    end

    // ==================================================================
    // PRODUTOR: apresenta o vetor i_send com valid_in aleatorio.
    // Os dados vem de vX[i_send]; como i_send so avanca no handshake,
    // os dados ficam ESTAVEIS ate serem aceitos (regra valid/ready).
    // ==================================================================
    always @(negedge clk) begin
        if (!rst) begin
            A             <= vA[i_send];
            B             <= vB[i_send];
            opcode        <= {1'b0, vOp[i_send]};
            rounding_mode <= vRm[i_send];
            valid_in      <= (i_send < NVEC) && (({$random} % 100) < pvalid);
            ready_in      <= (({$random} % 100) < pready);
        end
    end

    // avanca a entrada no handshake de entrada
    always @(posedge clk) begin
        if (!rst && valid_in && ready_out && i_send < NVEC)
            i_send <= i_send + 1;
    end

    // ==================================================================
    // CONSUMIDOR + SCOREBOARD: captura no handshake de saida, em ordem.
    // ==================================================================
    always @(posedge clk) begin
        if (!rst && valid_out && ready_in && i_recv < NVEC) begin
            check_output(i_recv, result, flags, exceptions);
            i_recv <= i_recv + 1;
            if (i_recv + 1 == NVEC) begin
                repeat(4) @(posedge clk);
                $display("\n=== RESULTADO: %0d PASS / %0d FAIL  (de %0d) ===",
                         pass_cnt, fail_cnt, NVEC);
                if (fail_cnt == 0)
                    $display("*** TODOS OS VETORES PASSARAM (com back-pressure) ***");
                else
                    $display("*** %0d FALHAS — handshake/aritmetica quebrados ***", fail_cnt);
                $finish;
            end
        end
    end

    // ==================================================================
    // WATCHDOG de stall: se i_recv nao avanca por muitos ciclos, deadlock.
    // ==================================================================
    always @(posedge clk) begin
        if (!rst) begin
            if (i_recv != last_recv) begin
                last_recv <= i_recv;
                stall_cyc <= 0;
            end else begin
                stall_cyc <= stall_cyc + 1;
                if (stall_cyc > 1000) begin
                    $display("\nDEADLOCK: i_send=%0d i_recv=%0d de %0d (sem progresso por >1000 ciclos)",
                             i_send, i_recv, NVEC);
                    $display("Parcial: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
                    $finish;
                end
            end
        end
    end

    // watchdog global de tempo
    initial begin
        #2000000000;
        $display("TIMEOUT global: i_send=%0d i_recv=%0d de %0d", i_send, i_recv, NVEC);
        $display("Parcial: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
