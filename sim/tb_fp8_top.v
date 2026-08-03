// ======================================================================
// tb_fp8_top.v  — testbench NIVEL-DE-PINO do wrapper STREAMING tt_um_fp8_fpu
//
// Exercita o TOP exatamente como o silicio sera usado: pelos pinos, com os
// handshakes valid/ready de entrada e saida (ver docs/PROTOCOL.md). Mantem
// VARIAS operacoes em voo (produtor adianta o consumidor), confere cada
// resultado contra o vectors.hex e MEDE latencia e II (ciclos/op).
//
// Modo: full (sem sticky, READ_FULL=1) -> 3 bytes in (A,B,CTRL), 3 bytes out
// (result,flags,exc). Assim valida result+flags+exc para vetores arbitrarios.
//
// Memoria: usa um RING buffer pequeno e le o vectors.hex SOB DEMANDA (nao
// carrega 1.3M em arrays). O produtor enche o ring a frente do consumidor.
//
// PLUSARGS:
//   +vecfile=<caminho>   caminho do vectors.hex (default: ../Golden_model/...)
//   +stride=N            processa 1 a cada N vetores (default 1)
//   +limit=N             para apos N vetores (0 = todos)
//   +stop_on_fail        aborta na primeira divergencia
//   +maxfail=N           quantas falhas imprimir (default 20)
//
// RODAR: use sim/run.do (set tb tb_fp8_top) ou sim/run_all.do.
// ======================================================================
`include "../src/header_fp8.v"
`timescale 1ns/1ps

module tb_fp8_top;

    // ------------------------------------------------------------------
    // Clock / reset / pinos
    // ------------------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;          // 100 MHz

    reg        rst_n;
    reg  [7:0] ui_in;
    reg  [7:0] uio_in;
    wire [7:0] uo_out;
    wire [7:0] uio_out;
    wire [7:0] uio_oe;
    reg        ena = 1'b1;

    // handshakes (nomes amigaveis)
    wire in_ready  = uio_out[1];
    wire out_valid = uio_out[2];
    wire fpu_busy  = uio_out[7];

    // bits que o host dirige em uio_in
    reg        drv_in_valid;
    reg        drv_out_ready;
    localparam STICKY_CTRL = 1'b0;   // full mode
    localparam STICKY_B    = 1'b0;
    localparam READ_FULL   = 1'b1;
    always @(*) begin
        uio_in = 8'h00;
        uio_in[0] = drv_in_valid;
        uio_in[3] = drv_out_ready;
        uio_in[4] = STICKY_CTRL;
        uio_in[5] = STICKY_B;
        uio_in[6] = READ_FULL;
    end

    // ------------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------------
    tt_um_fp8_fpu dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(ena), .clk(clk), .rst_n(rst_n)
    );

    // ------------------------------------------------------------------
    // RING buffer de operacoes (entre consumidor e produtor)
    // ------------------------------------------------------------------
    localparam integer RING = 1024;          // potencia de 2
    localparam integer RMASK = RING - 1;
    reg [7:0] rA   [0:RING-1];
    reg [7:0] rB   [0:RING-1];
    reg [7:0] rCtl [0:RING-1];               // {rm[2:0],opcode[4:0]}
    reg [7:0] rEr  [0:RING-1];               // expected result
    reg [7:0] rEf  [0:RING-1];               // expected flags (7b uteis)
    reg [7:0] rEx  [0:RING-1];               // expected exc   (5b uteis)

    integer wr_idx, send_idx, chk_idx;       // contadores monotonicos de op
    reg [1:0] send_byte, recv_byte;
    reg [7:0] capt0, capt1;                  // bytes result/flags capturados
    reg       done_loading;

    // estatisticas / medicao
    integer pass_cnt, fail_cnt, printed, maxfail;
    integer stride, limit, line_no;
    reg     stop_on_fail;
    integer ncyc, t_first_issue, t_first_res, t_last_res;

    // arquivo
    integer fd, code;
    reg [4095:0] vecpath, tbpath, simdir, rootdir;
    reg [7:0] ta, tb_, tres, tfl, tex;
    reg [3:0] top, trm;

    // ---- helpers de path (iguais aos outros TBs) ----
    function integer str_len;
        input [4095:0] s; integer i, started, n; reg [7:0] c;
        begin n=0; started=0;
            for (i=4095; i>=7; i=i-8) begin c=s[i-:8];
                if (c!=8'h00) started=1; if (started) n=n+1; end
            str_len=n; end
    endfunction
    function [4095:0] dirname_of;
        input [4095:0] s; integer len, cutpos, idx; reg [7:0] c; reg [4095:0] out;
        begin len=str_len(s); cutpos=-1;
            for (idx=0; idx<len; idx=idx+1) begin c=s[(len-idx)*8-1 -:8];
                if (c=="/"||c==8'h5C) cutpos=idx; end
            out=0;
            if (cutpos<0) out="."; else
                for (idx=0; idx<cutpos; idx=idx+1) begin
                    c=s[(len-idx)*8-1 -:8]; out=(out<<8)|c; end
            dirname_of=out; end
    endfunction
    function [4095:0] pjoin;
        input [4095:0] dir; input [4095:0] name; integer i,dl,nl; reg [7:0] c; reg [4095:0] out;
        begin dl=str_len(dir); nl=str_len(name); out=0;
            for (i=0;i<dl;i=i+1) begin c=dir[(dl-i)*8-1 -:8]; out=(out<<8)|c; end
            out=(out<<8)|"/";
            for (i=0;i<nl;i=i+1) begin c=name[(nl-i)*8-1 -:8]; out=(out<<8)|c; end
            pjoin=out; end
    endfunction

    // ------------------------------------------------------------------
    // Le e ARMAZENA a proxima operacao "mantida" (respeitando stride) no
    // ring. Retorna 1 se leu, 0 no fim do arquivo.
    // ------------------------------------------------------------------
    task read_one_op;
        output reg ok;
        integer slot;
        begin
            ok = 1'b0;
            while (ok == 1'b0) begin
                code = $fscanf(fd, "%h %h %h %h %h %h %h\n",
                               ta, tb_, top, trm, tres, tfl, tex);
                if (code != 7) begin
                    disable read_one_op;        // EOF
                end
                line_no = line_no + 1;
                if (((line_no-1) % stride) == 0) begin
                    slot = wr_idx & RMASK;
                    rA[slot]  = ta;
                    rB[slot]  = tb_;
                    // CTRL = {rm[2:0] em [7:5], opcode[4:0] em [4:0]}
                    rCtl[slot]= ({5'b0, trm[2:0]} << 5) | {4'b0, top[3:0]};
                    rEr[slot] = tres;
                    rEf[slot] = tfl;
                    rEx[slot] = tex;
                    // NAO-BLOQUEANTE: o loader e o produtor vivem no mesmo
                    // always @(posedge clk). Com '=', wr_idx subia no mesmo
                    // delta-cycle e 'have_op' virava 1 ANTES do proximo ciclo,
                    // fazendo o produtor adiantar send_byte 1 ciclo em relacao
                    // ao in_count do DUT -> stream A/B/CTRL desalinhado em 1 byte
                    // (o nucleo recebia A=rB, B=00). Com '<=' a disponibilidade
                    // so aparece no ciclo seguinte, em sincronia com o DUT.
                    wr_idx <= wr_idx + 1;
                    ok = 1'b1;
                end
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Combinacional: produtor dirige ui_in / in_valid
    // ------------------------------------------------------------------
    wire have_op  = (send_idx < wr_idx);
    wire [31:0] send_slot = send_idx & RMASK;
    always @(*) begin
        drv_in_valid  = have_op;
        drv_out_ready = 1'b1;                 // sempre drena (max throughput)
        case (send_byte)
            2'd0:    ui_in = rA [send_slot];
            2'd1:    ui_in = rB [send_slot];
            default: ui_in = rCtl[send_slot];
        endcase
    end

    // ------------------------------------------------------------------
    // Comparacao de um resultado completo
    // ------------------------------------------------------------------
    task check_result;
        input integer idx;
        input [7:0] g_res, g_flg, g_exc;
        integer slot; reg ok;
        reg [7:0] er, ef, ex;
        begin
            slot = idx & RMASK;
            er = rEr[slot]; ef = rEf[slot] & 8'h7f; ex = rEx[slot] & 8'h1f;
            ok = (g_res===er) && ((g_flg&8'h7f)===ef) && ((g_exc&8'h1f)===ex);
            if (ok) pass_cnt = pass_cnt + 1;
            else begin
                fail_cnt = fail_cnt + 1;
                if (printed < maxfail) begin
                    printed = printed + 1;
                    $display("FAIL op#%0d | res got=%02h exp=%02h | flags got=%07b exp=%07b | exc got=%05b exp=%05b",
                        idx, g_res, er, g_flg[6:0], ef[6:0], g_exc[4:0], ex[4:0]);
                end
                if (stop_on_fail) begin
                    $display("=== abortando na primeira falha (+stop_on_fail) ===");
                    report_and_finish;
                end
            end
        end
    endtask

    task report_and_finish;
        integer total, win;
        begin
            total = chk_idx;
            win = (t_last_res >= 0 && t_first_issue >= 0) ?
                  (t_last_res - t_first_issue) : 0;
            $display("\n=== STREAMING: %0d PASS / %0d FAIL  (de %0d resultados) ===",
                     pass_cnt, fail_cnt, total);
            $display("--- METRICAS (modelo de pinos, full mode 3in/3out) ---");
            $display("  latencia 1o resultado : %0d ciclos (issue->result)",
                     (t_first_res>=0 && t_first_issue>=0) ? (t_first_res - t_first_issue) : -1);
            if (total > 1 && win > 0)
                $display("  throughput (regime)   : %0d ciclos p/ %0d ops -> II ~ %0d.%02d ciclos/op",
                         win, total, win/total, ((win*100)/total)%100);
            if (fail_cnt==0 && total>0) $display("*** TODOS OS RESULTADOS PASSARAM ***");
            $finish;
        end
    endtask

    // ------------------------------------------------------------------
    // Motor sincrono: loader + produtor + consumidor
    // ------------------------------------------------------------------
    reg eng_on;
    reg ld_ok;
    always @(posedge clk) begin
        if (eng_on) begin
            ncyc <= ncyc + 1;

            // 1) LOADER: mantem o ring cheio a frente do consumidor
            if (!done_loading && ((wr_idx - chk_idx) < (RING-2))) begin
                if (limit != 0 && wr_idx >= limit) done_loading <= 1'b1;
                else begin
                    read_one_op(ld_ok);
                    if (!ld_ok) done_loading <= 1'b1;
                end
            end

            // 2) PRODUTOR: byte aceito? (in_valid & in_ready)
            if (have_op && in_ready) begin
                if (send_byte == 2'd2) begin            // CTRL = ultimo byte
                    if (t_first_issue < 0) t_first_issue <= ncyc;
                    send_byte <= 2'd0;
                    send_idx  <= send_idx + 1;
                end else send_byte <= send_byte + 2'd1;
            end

            // 3) CONSUMIDOR: byte produzido? (out_valid & out_ready=1)
            if (out_valid) begin
                if (recv_byte == 2'd0)      capt0 <= uo_out;     // result
                else if (recv_byte == 2'd1) capt1 <= uo_out;     // flags
                if (recv_byte == 2'd2) begin                     // exc (ultimo)
                    if (t_first_res < 0) t_first_res <= ncyc;
                    t_last_res <= ncyc;
                    check_result(chk_idx, capt0, capt1, uo_out);
                    recv_byte <= 2'd0;
                    chk_idx   <= chk_idx + 1;
                end else recv_byte <= recv_byte + 2'd1;
            end

            // 4) TERMINO: tudo carregado e tudo consumido
            if (done_loading && (chk_idx == wr_idx) && (wr_idx > 0))
                report_and_finish;
        end
    end

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------
    initial begin
        stride=1; limit=0; maxfail=20; stop_on_fail=1'b0;
        if (!$value$plusargs("stride=%d", stride)) stride=1;
        if (!$value$plusargs("limit=%d",  limit))  limit=0;
        if (!$value$plusargs("maxfail=%d",maxfail)) maxfail=20;
        if ($test$plusargs("stop_on_fail")) stop_on_fail=1'b1;
        if (stride < 1) stride=1;

        // resolve caminho do vectors.hex (agora em Golden_model/)
        fd = 0;
        if ($value$plusargs("vecfile=%s", vecpath)) fd=$fopen(vecpath,"r");
        if (fd==0) begin vecpath="../Golden_model/vectors.hex"; fd=$fopen(vecpath,"r"); end
        if (fd==0) begin
            tbpath=`__FILE__; simdir=dirname_of(tbpath); rootdir=dirname_of(simdir);
            vecpath=pjoin(rootdir,"Golden_model/vectors.hex"); fd=$fopen(vecpath,"r");
        end
        if (fd==0) begin
            $display("ERRO: nao consegui abrir vectors.hex (Golden_model/).");
            $display("  aponte com: vsim ... +vecfile=C:/caminho/vectors.hex");
            $finish;
        end
        $display(">> lendo vetores de: %0s", vecpath);
        $display(">> stride=%0d limit=%0d  (full mode 3in/3out)", stride, limit);

        // init regs do motor
        wr_idx=0; send_idx=0; chk_idx=0; send_byte=0; recv_byte=0;
        capt0=0; capt1=0; done_loading=0; line_no=0;
        pass_cnt=0; fail_cnt=0; printed=0;
        ncyc=0; t_first_issue=-1; t_first_res=-1; t_last_res=-1;
        eng_on=0;

        // reset
        rst_n=1'b0;
        repeat (5) @(posedge clk);
        rst_n=1'b1;
        @(posedge clk);
        if (uio_oe !== 8'b1000_0110)
            $display("AVISO: uio_oe=%b (esperado 10000110)", uio_oe);

        // pre-carrega algumas ops e liga o motor
        eng_on = 1'b1;

        // watchdog
        #2_000_000_000;
        $display("TIMEOUT: send=%0d chk=%0d wr=%0d", send_idx, chk_idx, wr_idx);
        report_and_finish;
    end

endmodule
