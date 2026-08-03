// ======================================================================
// tb_handshake_elastic.v  —  testbench do caminho ELASTICO (fp8_handshake_reg)
//
// Verifica o handshake valid/ready + skid buffer ISOLADO da aritmetica FP8.
// Os payloads sao contadores monotonicos (0,1,2,...), entao qualquer PERDA,
// DUPLICACAO ou REORDENACAO de transacao e' detectada por um scoreboard de
// ordem simples: a saida TEM que sair 0,1,2,... sem saltos nem repeticoes.
//
// Cobre exatamente o que os TBs de aritmetica nao cobrem:
//   - back-pressure (ready_in oscilando)
//   - bolhas na entrada (valid_in oscilando)
//   - flush no meio do stream
//
// Toda a temporizacao vive na task `tick`: aplica os estimulos na borda de
// descida (estaveis no posedge) e, no posedge, le os valores PRE-edge do DUT
// (as atribuicoes nao-bloqueantes do DUT so atualizam depois) para conferir a
// saida e avancar o produtor — um passo sincrono limpo, sem desalinhamento.
//
// FASES:
//   1) Dirigida   : sequencia determinística (sempre o mesmo resultado em
//                   qualquer simulador). Util como regressao.
//   2) Aleatoria  : 8 rodadas de back-pressure + bolhas.
//   3) Flush      : limpa o pipe no meio do stream.
//
// RODAR (ModelSim/Questa):
//   vlog fp8_handshake_reg.v tb_handshake_elastic.v
//   vsim -c tb_handshake_elastic -do "run -all; quit"
// RODAR (Icarus):
//   iverilog -g2012 -o sim fp8_handshake_reg.v tb_handshake_elastic.v && vvp sim
//
// Teste de sanidade (negativo): se quiser provar que o TB pega o bug, cole a
// logica antiga (ver verif_elastic/fp8_handshake_reg_buggy.v) no
// fp8_handshake_reg.v e rode de novo — a Fase 1 deve falhar (recebido
// 0 1 2 4 3 4) e o veredito final deve ser FAIL.
// ======================================================================
`timescale 1ns/1ps

module tb_handshake_elastic;

    localparam integer DW = 16;   // largura do payload
    localparam integer N  = 40;   // itens por fase

    reg              clk = 1'b0;
    reg              rst, flush;
    reg              valid_in, ready_in;
    reg  [DW-1:0]    data_in;
    wire             ready_out, valid_out;
    wire [DW-1:0]    data_out;

    fp8_handshake_reg #(.DATA_WIDTH(DW)) dut (
        .clk(clk), .rst(rst), .flush(flush),
        .valid_in(valid_in), .ready_out(ready_out),
        .data_in(data_in),
        .valid_out(valid_out), .data_out(data_out),
        .ready_in(ready_in)
    );

    always #5 clk = ~clk;

    integer send_ptr, exp_next, recv_cnt, err_cnt, cyc_cnt;
    reg     first_err;
    integer recv_seq [0:255];
    integer total_err;
    integer s, k;

    // sequencia DIRIGIDA. bit [21] = ciclo 0 (MSB-first).
    reg [21:0] DIR_VI;
    reg [21:0] DIR_RI;
    localparam integer DIR_LEN = 22;

    // ------------------------------------------------------------------
    // Um passo sincrono de transacao.
    //   vi/ri : valid_in / ready_in desejados neste ciclo.
    // Aplica na borda de descida; confere e avanca no posedge (pre-edge).
    // ------------------------------------------------------------------
    task tick;
        input vi;
        input ri;
        begin
            @(negedge clk);
            valid_in = vi & (send_ptr < N);
            data_in  = send_ptr[DW-1:0];
            ready_in = ri;

            @(posedge clk);   // DUT atualiza (NBA); leituras abaixo sao PRE-edge

            // saida (consumidor)
            if (valid_out && ready_in) begin
                recv_seq[recv_cnt] = data_out;
                recv_cnt = recv_cnt + 1;
                if (data_out !== exp_next[DW-1:0]) begin
                    err_cnt = err_cnt + 1;
                    if (!first_err) begin
                        first_err = 1'b1;
                        $display("  [FAIL] ciclo %0d: esperava %0d, recebeu %0d  <<< REORDER/PERDA/DUP",
                                 cyc_cnt, exp_next, data_out);
                    end
                end else begin
                    exp_next = exp_next + 1;
                end
            end

            // entrada (produtor) — usa ready_out PRE-edge
            if (valid_in && ready_out && (send_ptr < N))
                send_ptr = send_ptr + 1;

            cyc_cnt = cyc_cnt + 1;
        end
    endtask

    task do_reset;
        begin
            rst = 1'b1; flush = 1'b0;
            valid_in = 1'b0; ready_in = 1'b1; data_in = 0;
            send_ptr = 0; exp_next = 0; recv_cnt = 0; err_cnt = 0;
            cyc_cnt  = 0; first_err = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk) rst = 1'b0;
        end
    endtask

    task clear_counters;
        begin
            send_ptr = 0; exp_next = 0; recv_cnt = 0; err_cnt = 0;
            cyc_cnt  = 0; first_err = 1'b0;
        end
    endtask

    initial begin
        DIR_VI = 22'b0110101000101101110010;
        DIR_RI = 22'b0111110100001000011011;
        total_err = 0;

        $display("======================================================");
        $display(" TB caminho elastico — fp8_handshake_reg");
        $display("======================================================");

        // ---- Fase 1: dirigida (determinística) ----
        $display("\n--- Fase 1: sequencia dirigida (regressao) ---");
        do_reset;
        clear_counters;
        for (k = 0; k < DIR_LEN; k = k + 1)
            tick(DIR_VI[21 - k], DIR_RI[21 - k]);
        $write("  recebido:");
        for (k = 0; k < recv_cnt; k = k + 1) $write(" %0d", recv_seq[k]);
        $display("");
        $display("  erros=%0d", err_cnt);
        total_err = total_err + err_cnt;

        // ---- Fase 2: aleatoria ----
        $display("\n--- Fase 2: stress aleatorio (back-pressure + bolhas) ---");
        for (s = 1; s <= 8; s = s + 1) begin
            do_reset;
            clear_counters;
            k = 0;
            while (exp_next < N && k < 100000) begin
                tick((({$random} % 100) < 60), (({$random} % 100) < 60));
                k = k + 1;
            end
            if (k >= 100000)
                $display("  [rodada %0d] DEADLOCK: drenou %0d/%0d  erros=%0d", s, exp_next, N, err_cnt);
            else
                $display("  [rodada %0d] drenou %0d/%0d em %0d ciclos  erros=%0d", s, exp_next, N, cyc_cnt, err_cnt);
            total_err = total_err + err_cnt;
        end

        // ---- Fase 3: flush mid-stream ----
        $display("\n--- Fase 3: flush mid-stream ---");
        do_reset;
        @(negedge clk); valid_in=1; data_in=16'hAA; ready_in=0;
        @(posedge clk);
        @(negedge clk); valid_in=1; data_in=16'hBB; ready_in=0;
        @(posedge clk);
        @(negedge clk); flush=1; valid_in=0;
        @(posedge clk);
        @(negedge clk); flush=0;
        @(posedge clk);
        if (valid_out !== 1'b0) begin
            $display("  [FAIL] valid_out=%b apos flush (deveria ser 0)", valid_out);
            total_err = total_err + 1;
        end else
            $display("  [OK] flush limpou o pipe (valid_out=0)");

        // ---- Veredito ----
        $display("\n======================================================");
        if (total_err == 0)
            $display(" RESULTADO: PASS  (0 erros) -- caminho elastico OK");
        else
            $display(" RESULTADO: FAIL  (%0d erros) -- handshake quebrado", total_err);
        $display("======================================================");
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT global");
        $finish;
    end

endmodule
