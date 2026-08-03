// ======================================================================
// tb_fp8_golden.v — Testbench self-checking dirigido por vetores.
//
// Le vectors.hex (gerado por gen_vectors.py) com colunas:
//   A B opcode rm  res_golden flags_golden exc_golden   (tudo em hex)
//
// Para cada vetor: injeta no fp8_elastic_pipeline, captura a saida e
// compara resultado + flags + exceptions contra o golden.
//
// RESOLUCAO DE CAMINHO (portavel, sem caminho absoluto fixo):
//   1) +vecfile=<caminho>               override manual
//   2) <raiz_do_projeto>/vectors.hex    derivado de `__FILE__
//   3) "vectors.hex"                    relativo ao dir de trabalho
//
// `__FILE__ expande para o caminho deste .v em tempo de compilacao; como
// o TB mora na raiz do projeto, o vectors.hex e' procurado ao lado dele,
// independente de onde voce roda o vsim.
//
// Plusargs: +maxfail=N (default 50), +stop_on_fail
// ======================================================================
`include "../src/header_fp8.v"
`timescale 1ns/1ps

module tb_fp8_golden;

    localparam integer MAXV = 2000000;

    reg         clk, rst, flush;
    reg         valid_in;
    reg         ready_in;
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
    reg [4095:0] vecpath;   // caminho final do arquivo de vetores
    reg [4095:0] tbpath;    // caminho deste .v (via `__FILE__)
    reg [4095:0] rootdir;   // diretorio raiz derivado
    reg [7:0] ta, tb_, tres, tfl, tex;
    reg [3:0] top, trm;

    integer i_send;
    integer i_recv;
    integer pass_cnt, fail_cnt, printed;
    integer maxfail;
    reg     stop_on_fail;

    // ---- helpers de string para caminho portavel ----------------------
    // Verilog guarda strings com o ultimo char nos bits baixos. Tratamos
    // o vetor como bytes, ignorando o padding de zeros a esquerda.

    function integer str_len;
        input [4095:0] s;
        integer i, started, n;
        reg [7:0] c;
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

    // retorna o diretorio: tudo antes da ultima '/' ou '\'
    function [4095:0] dirname_of;
        input [4095:0] s;
        integer len, cutpos, idx;
        reg [7:0] c;
        reg [4095:0] out;
        begin
            len = str_len(s);
            cutpos = -1;
            for (idx = 0; idx < len; idx = idx + 1) begin
                c = s[(len-idx)*8-1 -: 8];
                if (c == "/" || c == 8'h5C) cutpos = idx;  // 8'h5C = '\'
            end
            out = 0;
            if (cutpos < 0) begin
                out = ".";
            end else begin
                for (idx = 0; idx < cutpos; idx = idx + 1) begin
                    c = s[(len-idx)*8-1 -: 8];
                    out = (out << 8) | c;
                end
            end
            dirname_of = out;
        end
    endfunction

    // junta dir + "/" + nome
    function [4095:0] pjoin;
        input [4095:0] dir;
        input [4095:0] name;
        integer i, dl, nl;
        reg [7:0] c;
        reg [4095:0] out;
        begin
            dl = str_len(dir);
            nl = str_len(name);
            out = 0;
            for (i = 0; i < dl; i = i + 1) begin
                c = dir[(dl-i)*8-1 -: 8];
                out = (out << 8) | c;
            end
            out = (out << 8) | "/";
            for (i = 0; i < nl; i = i + 1) begin
                c = name[(nl-i)*8-1 -: 8];
                out = (out << 8) | c;
            end
            pjoin = out;
        end
    endfunction

    // comparacao de uma saida contra o vetor esperado
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

    initial begin
        // ---- plusargs ----
        maxfail = 50;
        stop_on_fail = 1'b0;
        if ($value$plusargs("maxfail=%d", maxfail)) ;
        if ($test$plusargs("stop_on_fail")) stop_on_fail = 1'b1;

        // ---- resolucao do caminho do arquivo de vetores ----
        // Ordem de tentativa (a primeira que abrir vence):
        //   1) +vecfile=<caminho>        override explicito na linha do vsim
        //   2) $FP8_VEC (variavel de ambiente)   ex: set FP8_VEC=C:/.../vectors.hex
        //   3) "vectors.hex"             dir de trabalho da simulacao (work/)
        //   4) <dir deste .v>/vectors.hex   derivado de `__FILE__ (se absoluto)
        // A #3 cobre o caso normal: gere o vectors.hex na mesma pasta de
        // onde voce roda o vsim. As outras sao redes de seguranca.
        NVEC = 0;
        fd   = 0;

        if ($value$plusargs("vecfile=%s", vecpath))
            fd = $fopen(vecpath, "r");

        if (fd == 0) begin
            code = $value$plusargs("FP8_VEC=%s", vecpath); // raramente usado
            vecpath = "../Golden_model/vectors.hex";
            fd = $fopen(vecpath, "r");
        end

        if (fd == 0) begin
            tbpath  = `__FILE__;
            rootdir = dirname_of(dirname_of(tbpath));   // raiz do projeto
            vecpath = pjoin(rootdir, "Golden_model/vectors.hex");
            fd = $fopen(vecpath, "r");
        end

        if (fd == 0) begin
            $display("ERRO: nao consegui abrir o arquivo de vetores.");
            $display("  ultimo caminho tentado: '%0s'", vecpath);
            $display("  -> gere o arquivo na pasta de onde voce roda o vsim:");
            $display("        python gen_vectors.py --rne");
            $display("  -> ou aponte explicitamente:");
            $display("        vsim ... +vecfile=C:/seu/caminho/vectors.hex");
            $finish;
        end
        $display(">> lendo vetores de: %0s", vecpath);

        // ---- load ----
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
        $display("=== Carregados %0d vetores ===", NVEC);

        // ---- reset ----
        flush=0; valid_in=0; ready_in=1; A=0; B=0; opcode=0; rounding_mode=0;
        rst=1; repeat(3) @(posedge clk); rst=0; @(posedge clk);

        pass_cnt=0; fail_cnt=0; printed=0;
        i_send=0; i_recv=0;
    end

    // ---- INJECAO ----
    always @(negedge clk) begin
        if (!rst) begin
            if (i_send < NVEC) begin
                A             <= vA[i_send];
                B             <= vB[i_send];
                opcode        <= {1'b0, vOp[i_send]};
                rounding_mode <= vRm[i_send];
                valid_in      <= 1'b1;
            end else begin
                valid_in      <= 1'b0;
            end
            ready_in <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst && valid_in && ready_out && i_send < NVEC)
            i_send <= i_send + 1;
    end

    // ---- DRENO ----
    always @(posedge clk) begin
        if (!rst && valid_out && ready_in) begin
            check_output(i_recv, result, flags, exceptions);
            i_recv <= i_recv + 1;
            if (i_recv + 1 == NVEC) begin
                repeat(4) @(posedge clk);
                $display("\n=== RESULTADO: %0d PASS / %0d FAIL  (de %0d) ===",
                         pass_cnt, fail_cnt, NVEC);
                if (fail_cnt == 0)
                    $display("*** TODOS OS VETORES PASSARAM ***");
                $finish;
            end
        end
    end

    // ---- watchdog ----
    initial begin
        #500000000;
        $display("TIMEOUT: i_send=%0d i_recv=%0d de %0d", i_send, i_recv, NVEC);
        $display("Parcial: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
