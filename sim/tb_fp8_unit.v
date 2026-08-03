// ======================================================================
// tb_fp8_unit.v
//
// Teste PONTA-A-PONTA da tiny_fp8_unit (controller + elastic_pipeline).
//
// Dirige a interface de issue com o vectors.hex (mesmo formato do golden),
// atribuindo uma TAG `rd` = (indice % 32) a cada operacao, e aplica
// back-pressure aleatorio no writeback (wb_ready). Como a unidade e'
// in-order, o scoreboard confere, para cada writeback i:
//     wb_result = res_golden[i]
//     wb_flags  = flags_golden[i]
//     wb_exc    = exc_golden[i]
//     wb_rd     = i % 32                (casamento tag<->resultado)
//
// Junta tudo o que ja foi certificado em separado: aritmetica (golden),
// caminho elastico (skid sob back-pressure) e controller (FIFO de rd).
//
// PLUSARGS:
//   +vecfile=<caminho>   override do vectors.hex
//   +maxvec=<N>          usa so os primeiros N vetores (smoke)
//   +maxfail=<N>         limite de prints de falha (default 30)
//   +pvalid=<0..100>     prob. de issue_valid por ciclo (default 70)
//   +pready=<0..100>     prob. de wb_ready por ciclo (default 70)
//   +stop_on_fail        aborta na primeira falha
//
// RODAR (ModelSim/Questa), da pasta com o vectors.hex:
//   vlog header_fp8.v fp8_unpack.v fp8_pre_execute.v fp8_execute_comb.v \
//        fp8_normalize.v fp8_round.v fp8_handshake_reg.v \
//        fp8_elastic_pipeline.v fp8_controller.v tiny_fp8_unit.v \
//        tb_fp8_unit.v
//   vsim -c tb_fp8_unit -do "run -all; quit"
//   # smoke:
//   vsim -c tb_fp8_unit +maxvec=5000 -do "run -all; quit"
//   # estresse de back-pressure:
//   vsim -c tb_fp8_unit +pready=15 +pvalid=95 -do "run -all; quit"
// ======================================================================
`include "../src/header_fp8.v"
`timescale 1ns/1ps

module tb_fp8_unit;

    localparam integer MAXV = 2000000;

    reg                    clk, rst, flush;

    // issue
    reg                    issue_valid;
    wire                   issue_ready;
    reg  [7:0]             issue_A, issue_B;
    reg  [`OP_WIDTH-1:0]   issue_opcode;
    reg  [2:0]             issue_rm;
    reg  [4:0]             issue_rd;

    // writeback
    wire                   wb_valid;
    reg                    wb_ready;
    wire [7:0]             wb_result;
    wire [`FLAG_WIDTH-1:0] wb_flags;
    wire [`EXC_WIDTH-1:0]  wb_exceptions;
    wire [4:0]             wb_rd;

    wire                   fpu_busy;

    tiny_fp8_unit #(.RD_FIFO_DEPTH(8)) dut (
        .clk(clk), .rst(rst),
        .issue_valid(issue_valid), .issue_ready(issue_ready),
        .issue_A(issue_A), .issue_B(issue_B),
        .issue_opcode(issue_opcode), .issue_rm(issue_rm), .issue_rd(issue_rd),
        .wb_valid(wb_valid), .wb_ready(wb_ready),
        .wb_result(wb_result), .wb_flags(wb_flags),
        .wb_exceptions(wb_exceptions), .wb_rd(wb_rd),
        .fpu_busy(fpu_busy), .flush(flush)
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

    integer NVEC, fd, code;
    reg [4095:0] vecpath, tbpath, rootdir;
    reg [7:0] ta, tb_, tres, tfl, tex;
    reg [3:0] top, trm;

    integer i_send, i_recv;
    integer pass_cnt, fail_cnt, printed;
    integer maxfail, maxvec, pvalid, pready;
    reg     stop_on_fail;
    integer last_recv, stall_cyc;

    // ---- helpers de caminho portavel (iguais ao golden) --------------
    function integer str_len;
        input [4095:0] s; integer i, started, n; reg [7:0] c;
        begin
            n=0; started=0;
            for (i=4095; i>=7; i=i-8) begin
                c = s[i -: 8];
                if (c != 8'h00) started = 1;
                if (started) n = n + 1;
            end
            str_len = n;
        end
    endfunction
    function [4095:0] dirname_of;
        input [4095:0] s; integer len, cutpos, idx; reg [7:0] c; reg [4095:0] out;
        begin
            len=str_len(s); cutpos=-1;
            for (idx=0; idx<len; idx=idx+1) begin
                c = s[(len-idx)*8-1 -: 8];
                if (c=="/" || c==8'h5C) cutpos=idx;
            end
            out=0;
            if (cutpos<0) out=".";
            else for (idx=0; idx<cutpos; idx=idx+1) begin
                c = s[(len-idx)*8-1 -: 8]; out=(out<<8)|c;
            end
            dirname_of=out;
        end
    endfunction
    function [4095:0] pjoin;
        input [4095:0] dir; input [4095:0] name;
        integer i, dl, nl; reg [7:0] c; reg [4095:0] out;
        begin
            dl=str_len(dir); nl=str_len(name); out=0;
            for (i=0;i<dl;i=i+1) begin c=dir[(dl-i)*8-1 -: 8]; out=(out<<8)|c; end
            out=(out<<8)|"/";
            for (i=0;i<nl;i=i+1) begin c=name[(nl-i)*8-1 -: 8]; out=(out<<8)|c; end
            pjoin=out;
        end
    endfunction

    // ---- checagem de um writeback contra o vetor i_recv --------------
    task check_output;
        input integer idx;
        input [7:0] got_res;
        input [`FLAG_WIDTH-1:0] got_fl;
        input [`EXC_WIDTH-1:0]  got_ex;
        input [4:0] got_rd;
        reg res_ok, fl_ok, ex_ok, rd_ok;
        reg [7:0] e_res, e_fl, e_ex;
        reg [4:0] e_rd;
        begin
            e_res = vRes[idx]; e_fl = vFl[idx]; e_ex = vEx[idx];
            e_rd  = idx % 32;
            res_ok = (got_res === e_res);
            fl_ok  = (got_fl  === e_fl[`FLAG_WIDTH-1:0]);
            ex_ok  = (got_ex  === e_ex[`EXC_WIDTH-1:0]);
            rd_ok  = (got_rd  === e_rd);
            if (res_ok && fl_ok && ex_ok && rd_ok) begin
                pass_cnt = pass_cnt + 1;
            end else begin
                fail_cnt = fail_cnt + 1;
                if (printed < maxfail) begin
                    printed = printed + 1;
                    $display("FAIL #%0d A=%02h B=%02h op=%0d rm=%0d | res %02h/%02h %s | flags %07b/%07b %s | exc %05b/%05b %s | rd %0d/%0d %s",
                        idx, vA[idx], vB[idx], vOp[idx], vRm[idx],
                        got_res, e_res, res_ok?"":"<<",
                        got_fl,  e_fl[`FLAG_WIDTH-1:0], fl_ok?"":"<<",
                        got_ex,  e_ex[`EXC_WIDTH-1:0], ex_ok?"":"<<",
                        got_rd,  e_rd, rd_ok?"":"<<");
                end
                if (stop_on_fail) begin
                    $display("=== abortando na primeira falha (+stop_on_fail) ===");
                    $finish;
                end
            end
        end
    endtask

    // ==================================================================
    // Setup
    // ==================================================================
    initial begin
        maxfail=30; stop_on_fail=1'b0; maxvec=0; pvalid=70; pready=70;
        if ($value$plusargs("maxfail=%d", maxfail)) ;
        if ($value$plusargs("maxvec=%d",  maxvec))  ;
        if ($value$plusargs("pvalid=%d",  pvalid))  ;
        if ($value$plusargs("pready=%d",  pready))  ;
        if ($test$plusargs("stop_on_fail")) stop_on_fail=1'b1;

        NVEC=0; fd=0;
        if ($value$plusargs("vecfile=%s", vecpath)) fd=$fopen(vecpath,"r");
        if (fd==0) begin vecpath="../Golden_model/vectors.hex"; fd=$fopen(vecpath,"r"); end
        if (fd==0) begin
            tbpath=`__FILE__; rootdir=dirname_of(dirname_of(tbpath));
            vecpath=pjoin(rootdir,"Golden_model/vectors.hex"); fd=$fopen(vecpath,"r");
        end
        if (fd==0) begin
            $display("ERRO: nao consegui abrir vectors.hex.");
            $display("  aponte com: vsim ... +vecfile=C:/caminho/vectors.hex");
            $finish;
        end
        $display(">> lendo vetores de: %0s", vecpath);

        while (!$feof(fd)) begin
            code = $fscanf(fd, "%h %h %h %h %h %h %h\n", ta, tb_, top, trm, tres, tfl, tex);
            if (code==7) begin
                vA[NVEC]=ta; vB[NVEC]=tb_; vOp[NVEC]=top; vRm[NVEC]=trm;
                vRes[NVEC]=tres; vFl[NVEC]=tfl; vEx[NVEC]=tex;
                NVEC=NVEC+1;
            end
        end
        $fclose(fd);
        if (maxvec>0 && maxvec<NVEC) NVEC=maxvec;
        $display("=== %0d vetores | tiny_fp8_unit | pvalid=%0d%% pready=%0d%% ===",
                 NVEC, pvalid, pready);

        // reset
        flush=0; issue_valid=0; wb_ready=1;
        issue_A=0; issue_B=0; issue_opcode=0; issue_rm=0; issue_rd=0;
        rst=1; repeat(3) @(posedge clk); rst=0; @(posedge clk);

        pass_cnt=0; fail_cnt=0; printed=0;
        i_send=0; i_recv=0; last_recv=0; stall_cyc=0;
    end

    // ==================================================================
    // PRODUTOR (issue): apresenta o vetor i_send com tag rd=i_send%32.
    // Dados ficam estaveis ate o handshake (i_send so avanca no aceite).
    // ==================================================================
    always @(negedge clk) begin
        if (!rst) begin
            issue_A      <= vA[i_send];
            issue_B      <= vB[i_send];
            issue_opcode <= {1'b0, vOp[i_send]};
            issue_rm     <= vRm[i_send][2:0];
            issue_rd     <= i_send % 32;
            issue_valid  <= (i_send < NVEC) && (({$random} % 100) < pvalid);
            wb_ready     <= (({$random} % 100) < pready);
        end
    end

    always @(posedge clk) begin
        if (!rst && issue_valid && issue_ready && i_send < NVEC)
            i_send <= i_send + 1;
    end

    // ==================================================================
    // CONSUMIDOR + SCOREBOARD (writeback), em ordem.
    // ==================================================================
    always @(posedge clk) begin
        if (!rst && wb_valid && wb_ready && i_recv < NVEC) begin
            check_output(i_recv, wb_result, wb_flags, wb_exceptions, wb_rd);
            i_recv <= i_recv + 1;
            if (i_recv + 1 == NVEC) begin
                repeat(4) @(posedge clk);
                $display("\n=== RESULTADO: %0d PASS / %0d FAIL  (de %0d) ===",
                         pass_cnt, fail_cnt, NVEC);
                if (fail_cnt == 0)
                    $display("*** UNIDADE OK: result+flags+exc+rd corretos sob back-pressure ***");
                else
                    $display("*** %0d FALHAS na unidade ***", fail_cnt);
                $finish;
            end
        end
    end

    // ==================================================================
    // WATCHDOG de stall
    // ==================================================================
    always @(posedge clk) begin
        if (!rst) begin
            if (i_recv != last_recv) begin last_recv <= i_recv; stall_cyc <= 0; end
            else begin
                stall_cyc <= stall_cyc + 1;
                if (stall_cyc > 1000) begin
                    $display("\nDEADLOCK: i_send=%0d i_recv=%0d de %0d", i_send, i_recv, NVEC);
                    $display("Parcial: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
                    $finish;
                end
            end
        end
    end

    initial begin
        #2000000000;
        $display("TIMEOUT global: i_send=%0d i_recv=%0d de %0d", i_send, i_recv, NVEC);
        $display("Parcial: %0d PASS / %0d FAIL", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
