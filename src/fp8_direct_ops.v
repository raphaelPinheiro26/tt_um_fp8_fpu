// ======================================================================
// fp8_direct_ops.v  —  Operacoes "diretas" (sem datapath aritmetico):
//   MIN, MAX (IEEE-2019, NaN propaga), ABS, CLASSIFY, COMPARE.
// Todas combinacionais; o resultado entra pelo caminho "especial" do
// pipeline (do_direct=1), com a mesma latencia das ops rapidas.
//
// Encodings de saida:
//   CLASSIFY -> result[3:0] = enum IEEE (0..9):
//       0 sNaN(n/a) 1 qNaN 2 -inf 3 -normal 4 -sub 5 -0 6 +0 7 +sub 8 +normal 9 +inf
//   COMPARE  -> result[3:0] = {unordered, gt, eq, lt}   (one-hot; -0==+0)
//   MIN/MAX/ABS -> result = FP8, flags = classificacao do resultado
// ======================================================================
`include "header_fp8.v"

module fp8_direct_ops (
    input  wire [7:0]             A,
    input  wire [7:0]             B,
    input  wire [`OP_WIDTH-1:0]   opcode,
    input  wire [2:0]             rounding_mode,
    input  wire                   signA, signB,
    input  wire [`FLAG_WIDTH-1:0] flagsA, flagsB,
    output reg                    do_direct,
    output reg  [7:0]             dr_result,
    output reg  [`FLAG_WIDTH-1:0] dr_flags,
    output reg  [`EXC_WIDTH-1:0]  dr_exc
);
    localparam [7:0] CANON_NAN = 8'b0_1111_001;

    wire a_nan = flagsA[`FLAG_NAN];
    wire b_nan = flagsB[`FLAG_NAN];
    wire [6:0] magA = A[6:0];
    wire [6:0] magB = B[6:0];
    wire bothzero = (magA == 7'b0) && (magB == 7'b0);

    // Bits de flag que este modulo intencionalmente nao usa (so' precisa de
    // NAN/INF/NORMAL/SUBNORMAL de A e de NAN de B). Sink explicito p/ o linter.
    wire _unused_do = &{1'b0, flagsA[6:5], flagsA[0], flagsB[6:5], flagsB[3:0]};

    // ---- comparacao real de A e B (ambos nao-NaN) -> lt/eq/gt ----
    reg cmp_lt, cmp_eq, cmp_gt;
    always @(*) begin
        cmp_lt = 1'b0; cmp_eq = 1'b0; cmp_gt = 1'b0;
        if (bothzero) begin
            cmp_eq = 1'b1;                        // -0 == +0
        end else if (signA != signB) begin
            if (signA) cmp_lt = 1'b1;             // A<0<B
            else       cmp_gt = 1'b1;
        end else if (magA == magB) begin
            cmp_eq = 1'b1;
        end else if (!signA) begin               // ambos +
            if (magA < magB) cmp_lt = 1'b1; else cmp_gt = 1'b1;
        end else begin                           // ambos -
            if (magA < magB) cmp_gt = 1'b1; else cmp_lt = 1'b1;
        end
    end

    // ---- classificacao de um codigo FP8 -> vetor de flags interno ----
    function [`FLAG_WIDTH-1:0] classify_flags;
        input [6:0] c;                       // magnitude (o sinal nao afeta a classe)
        reg [3:0] e; reg [2:0] m; reg [`FLAG_WIDTH-1:0] f;
        begin
            e = c[6:3]; m = c[2:0]; f = {`FLAG_WIDTH{1'b0}};
            if (e == 4'hF && m != 0)      begin f[`FLAG_NAN]=1'b1; f[`FLAG_QNAN]=1'b1; end
            else if (e == 4'hF)            f[`FLAG_INF]=1'b1;
            else if (e == 4'h0 && m == 0)  f[`FLAG_ZERO]=1'b1;
            else if (e == 4'h0)            f[`FLAG_SUBNORMAL]=1'b1;
            else                           f[`FLAG_NORMAL]=1'b1;
            classify_flags = f;
        end
    endfunction

    // ---- enum de classe IEEE (0..9) ----
    reg [3:0] cls;
    always @(*) begin
        if (flagsA[`FLAG_NAN])            cls = 4'd1;   // qNaN (E4M3 sem sNaN)
        else if (flagsA[`FLAG_INF])       cls = signA ? 4'd2 : 4'd9;
        else if (flagsA[`FLAG_NORMAL])    cls = signA ? 4'd3 : 4'd8;
        else if (flagsA[`FLAG_SUBNORMAL]) cls = signA ? 4'd4 : 4'd7;
        else                              cls = signA ? 4'd5 : 4'd6; // zero
    end

    // ---- decisao de arredondamento (igual a fp8_round.do_round) ----
    function do_round;
        input [2:0] rm; input sgn; input lsb, gg, rr, ss;
        reg inx; begin
            inx = gg | rr | ss;
            case (rm)
                3'b000: do_round = gg & (rr | ss | lsb);
                3'b001: do_round = 1'b0;
                3'b010: do_round = (~sgn) & inx;
                3'b011: do_round = ( sgn) & inx;
                3'b100: do_round = inx & (~lsb);
                default: do_round = 1'b0;
            endcase
        end
    endfunction

    // ---- ROUNDINT: arredonda A ao inteiro (sem NX) ----
    wire        ri_norm = flagsA[`FLAG_NORMAL];
    wire [3:0]  ri_ef   = A[6:3];
    wire [2:0]  ri_m    = A[2:0];
    wire [3:0]  ri_sig4 = ri_norm ? {1'b1, ri_m} : {1'b0, ri_m};
    wire signed [5:0] ri_E = ri_norm ? ($signed({2'b0, ri_ef}) - 6'sd7) : -6'sd6;
    reg  [4:0]  ri_sa;                        // shift = 3 - E (>=1 no caminho fracionario)
    reg  [4:0]  ri_sm1;                        // ri_sa - 1 (indice/guarda)
    reg  [3:0]  ri_int;                        // parte inteira
    reg  [3:0]  ri_smask;                      // mascara sticky (bits de ri_sig4)
    reg         ri_g, ri_s;
    reg  [3:0]  ri_incd;                       // inteiro arredondado (0..8)
    reg  [7:0]  ri_res;
    reg  [3:0]  ri_ef_o; reg [2:0] ri_m_o; reg [2:0] ri_p;
    always @(*) begin
        // shift = 3 - E, em 5 bits sem sinal:
        //   normal -> 3 - (ef-7) = 10 - ef ;  subnormal -> 3 - (-6) = 9
        ri_sa   = ri_norm ? (5'd10 - {1'b0, ri_ef}) : 5'd9;
        ri_sm1  = ri_sa - 5'd1;
        ri_int  = ri_sig4 >> ri_sa;                       // 0 se sa>=4
        ri_g    = (ri_sa >= 5'd1 && ri_sa <= 5'd4) ? ri_sig4[ri_sm1[1:0]] : 1'b0;
        // sticky: bits de ri_sig4 abaixo do guard
        ri_smask = (4'd1 << ri_sm1) - 4'd1;
        ri_s    = |(ri_sig4 & ri_smask);
        ri_incd = ri_int + {3'b000, do_round(rounding_mode, signA, ri_int[0], ri_g, 1'b0, ri_s)};
        // defaults (evita latch: estes sinais so' sao usados no ramo else)
        ri_p    = 3'd0;
        ri_ef_o = 4'd0;
        ri_m_o  = 3'd0;
        // re-encode ri_incd (magnitude 0..8) em FP8
        if (ri_incd == 4'd0) begin
            ri_res = {signA, 7'b0};
        end else begin
            // posicao do MSB
            ri_p = ri_incd[3] ? 3'd3 : ri_incd[2] ? 3'd2 : ri_incd[1] ? 3'd1 : 3'd0;
            ri_ef_o = {1'b0, ri_p} + 4'd7;
            ri_m_o  = ri_incd[2:0] << (3'd3 - ri_p);
            ri_res  = {signA, ri_ef_o, ri_m_o};
        end
    end

    always @(*) begin
        do_direct = 1'b1;
        dr_result = 8'h00;
        dr_flags  = {`FLAG_WIDTH{1'b0}};
        dr_exc    = {`EXC_WIDTH{1'b0}};
        case (opcode)
            `OPCODE_ABS: begin
                dr_result = {1'b0, A[6:0]};
                dr_flags  = classify_flags(dr_result[6:0]);
            end
            // negate(A): copia A com o bit de sinal invertido (inclusive
            // para +-0, +-Inf e NaN). Operacao de bit, sem excecoes.
            `OPCODE_NEG: begin
                dr_result = {~A[7], A[6:0]};
                dr_flags  = classify_flags(dr_result[6:0]);
            end
            // copySign(A,B): magnitude/payload de A com o sinal de B.
            // Operacao de bit (nao sinaliza em NaN), sem excecoes.
            `OPCODE_COPYSIGN: begin
                dr_result = {B[7], A[6:0]};
                dr_flags  = classify_flags(dr_result[6:0]);
            end
            `OPCODE_CLASSIFY: begin
                dr_result = {4'b0, cls};
            end
            `OPCODE_COMPARE: begin
                if (a_nan || b_nan) dr_result = {4'b0, 1'b1, 3'b000};   // unordered
                else                dr_result = {4'b0, 1'b0, cmp_gt, cmp_eq, cmp_lt};
            end
            `OPCODE_MIN: begin
                if (a_nan || b_nan) begin
                    dr_result = CANON_NAN; dr_flags = classify_flags(CANON_NAN[6:0]);
                end else if (bothzero) begin
                    dr_result = {signA | signB, 7'b0};   // -0 se qualquer -0
                    dr_flags  = classify_flags(dr_result[6:0]);
                end else begin
                    dr_result = cmp_lt ? A : B;
                    dr_flags  = classify_flags(dr_result[6:0]);
                end
            end
            `OPCODE_MAX: begin
                if (a_nan || b_nan) begin
                    dr_result = CANON_NAN; dr_flags = classify_flags(CANON_NAN[6:0]);
                end else if (bothzero) begin
                    dr_result = {signA & signB, 7'b0};   // +0 a menos que ambos -0
                    dr_flags  = classify_flags(dr_result[6:0]);
                end else begin
                    dr_result = cmp_lt ? B : A;
                    dr_flags  = classify_flags(dr_result[6:0]);
                end
            end
            `OPCODE_ROUNDINT: begin
                if (flagsA[`FLAG_NAN]) begin
                    dr_result = {signA, 4'b1111, A[2:0]};
                    dr_flags  = classify_flags(dr_result[6:0]);
                end else if (flagsA[`FLAG_INF]) begin
                    dr_result = {signA, 4'b1111, 3'b000};
                    dr_flags[`FLAG_INF] = 1'b1;
                end else if (ri_E >= 6'sd3) begin
                    dr_result = A;                       // ja' inteiro
                    dr_flags  = classify_flags(A[6:0]);
                end else begin
                    dr_result = ri_res;                  // arredondado
                    dr_flags  = classify_flags(ri_res[6:0]);
                end
            end
            default: do_direct = 1'b0;   // nao e' op direta
        endcase
    end
endmodule
