// ======================================================================
// MÓDULO 3: fp8_execute_comb  (CAMINHO 2 — régua larga, pré-normalizada)
// ======================================================================
// Reescrito para o algoritmo unificado "Caminho 2":
//   1. Pré-normaliza CADA operando para a forma 1.mmm × 2^(e_real),
//      inclusive subnormais (que passam a ter hidden bit = 1 e um e_real
//      mais negativo). Isso elimina o antigo expA_w=1 fixo, que corrompia
//      o expoente de subnormais.
//   2. Opera (ADD/SUB/MULT/DIV) sobre mantissas com hidden=1, em um
//      acumulador/produto/quociente largo que NÃO perde sticky.
//
// A NORMALIZAÇÃO (levar o resultado ao topo da régua de 16 bits) NÃO é
// mais feita aqui — ela foi movida para o módulo fp8_normalize, que vive
// no próprio estágio de pipeline entre o execute e o round. Este módulo
// agora entrega apenas o resultado CRU de cada operação:
//
// Convenção da saída (cru, consumido por fp8_normalize):
//   exec_sign     – sinal do resultado (já selecionado pelo opcode)
//   exec_is_zero  – resultado exatamente zero (já selecionado pelo opcode)
//   ADD/SUB : exec_acc   (acumulador de NRM_ACCW bits, sticky no bit0)
//             exec_big_e (expoente real do maior operando)
//   MULT    : exec_prod  (produto 4x4 = 8 bits)
//             exec_e_base (eA_r + eB_r)
//   DIV     : exec_quot  (quociente, NRM_QDIV+5 bits)
//             exec_e_div0 (eA_r - eB_r)
//             exec_remnz  (resto != 0 -> sticky)
//
// ======================================================================
`include "header_fp8.v"

module fp8_execute_comb (
    input  wire                    signA, signB,
    input  wire [3:0]              expA, expB,
    input  wire [2:0]              mantA, mantB,
    input  wire [`FLAG_WIDTH-1:0]  flagsA, flagsB,
    input  wire [`OP_WIDTH-1:0]    opcode,
    input  wire                    signB_eff,

    output wire                    exec_sign,
    output wire                    exec_is_zero,
    // ADD/SUB cru
    output wire [`NRM_ACCW-1:0]    exec_acc,
    output wire signed [5:0]       exec_big_e,
    // MULT cru
    output wire [7:0]              exec_prod,
    output wire signed [5:0]       exec_e_base,
    // DIV cru
    output wire [`NRM_QDIV+4:0]    exec_quot,
    output wire signed [5:0]       exec_e_div0,
    output wire                    exec_remnz
);
    localparam signed [5:0] BIAS_S = 6'sd7;
    localparam signed [5:0] EMIN_S = -6'sd6;   // 1 - bias

    wire a_sub = flagsA[`FLAG_SUBNORMAL];
    wire b_sub = flagsB[`FLAG_SUBNORMAL];
    wire a_nrm = flagsA[`FLAG_NORMAL];
    wire b_nrm = flagsB[`FLAG_NORMAL];

    // ------------------------------------------------------------------
    // PRÉ-NORMALIZAÇÃO de cada operando -> (mant4 = 1.mmm, e_real)
    //   normal:    mant4 = {1,mant},      e_real = exp - bias
    //   subnormal: desloca p/ 1.xxx,      e_real = emin - shift - 1
    //     mant=1xx -> shift 0 -> e_real = emin-1
    //     mant=01x -> shift 1 -> e_real = emin-2
    //     mant=001 -> shift 2 -> e_real = emin-3
    // ------------------------------------------------------------------
    reg  [3:0]       mA4, mB4;
    reg  signed [5:0] eA_r, eB_r;
    reg              zA, zB;

    always @(*) begin
        // operando A
        if (a_nrm) begin
            mA4  = {1'b1, mantA};
            eA_r = $signed({2'b00, expA}) - BIAS_S;
            zA   = 1'b0;
        end else if (a_sub) begin
            zA = 1'b0;
            if (mantA[2]) begin
                mA4  = {mantA[2:0], 1'b0};      // 1xx -> shift 1 p/ pôr no topo de 4b
                eA_r = EMIN_S - 6'sd1;
            end else if (mantA[1]) begin
                mA4  = {mantA[1:0], 2'b00};
                eA_r = EMIN_S - 6'sd2;
            end else begin
                mA4  = {mantA[0], 3'b000};
                eA_r = EMIN_S - 6'sd3;
            end
        end else begin
            mA4 = 4'b0000; eA_r = 6'sd0; zA = 1'b1;
        end
        // operando B
        if (b_nrm) begin
            mB4  = {1'b1, mantB};
            eB_r = $signed({2'b00, expB}) - BIAS_S;
            zB   = 1'b0;
        end else if (b_sub) begin
            zB = 1'b0;
            if (mantB[2]) begin
                mB4  = {mantB[2:0], 1'b0};
                eB_r = EMIN_S - 6'sd1;
            end else if (mantB[1]) begin
                mB4  = {mantB[1:0], 2'b00};
                eB_r = EMIN_S - 6'sd2;
            end else begin
                mB4  = {mantB[0], 3'b000};
                eB_r = EMIN_S - 6'sd3;
            end
        end else begin
            mB4 = 4'b0000; eB_r = 6'sd0; zB = 1'b1;
        end
    end

    // ==================================================================
    // ADD / SUB  — acumulador largo (sem perda de sticky)
    // ==================================================================
    // Cada mantissa 1.mmm (4 bits, hidden em bit3) é colocada num
    // acumulador deslocado por G=20 para guarda ampla no alinhamento.
    localparam integer G = `NRM_G;
    localparam integer ACCW = `NRM_ACCW;   // largura do acumulador (folga p/ carry) = 4 + G + 2

    reg                 as_sign;
    reg                 as_zero;
    reg  [ACCW-1:0]     as_acc;            // acumulador (magnitude)
    reg  signed [5:0]   as_big_e;

    reg  signed [5:0]   big_e, small_e;
    reg                 big_s, small_s;
    reg  [ACCW-1:0]     big_m, small_m, small_sh;
    reg  [5:0]          d_align;
    reg                 sticky_align;

    always @(*) begin
        // defaults p/ TODAS as variáveis (evita latches inferidos):
        // toda variável recebe um valor em todo caminho do bloco @(*).
        big_e        = 6'sd0;
        big_s        = 1'b0;
        small_e      = 6'sd0;
        small_s      = 1'b0;
        big_m        = {ACCW{1'b0}};
        small_m      = {ACCW{1'b0}};
        small_sh     = {ACCW{1'b0}};
        d_align      = 6'd0;
        sticky_align = 1'b0;
        as_sign      = 1'b0;
        as_zero      = 1'b0;
        as_acc       = {ACCW{1'b0}};
        as_big_e     = 6'sd0;

        // seleciona maior expoente
        if (zA && zB) begin
            as_sign = signA & signB_eff; as_zero = 1'b1; as_acc = {ACCW{1'b0}};
            as_big_e = 6'sd0;
        end else if (zA) begin
            // 0 ± B  -> B (com sinal efetivo)
            as_sign = signB_eff; as_zero = 1'b0;
            as_acc = {1'b0, mB4, {G{1'b0}}, 1'b0};
            as_big_e = eB_r;
        end else if (zB) begin
            as_sign = signA; as_zero = 1'b0;
            as_acc = {1'b0, mA4, {G{1'b0}}, 1'b0};
            as_big_e = eA_r;
        end else begin
            // ambos não-zero: alinhar
            if (eA_r >= eB_r) begin
                big_e = eA_r; big_s = signA;   big_m = {1'b0, mA4, {G{1'b0}}, 1'b0};
                small_e = eB_r; small_s = signB_eff; small_m = {1'b0, mB4, {G{1'b0}}, 1'b0};
            end else begin
                big_e = eB_r; big_s = signB_eff; big_m = {1'b0, mB4, {G{1'b0}}, 1'b0};
                small_e = eA_r; small_s = signA; small_m = {1'b0, mA4, {G{1'b0}}, 1'b0};
            end
            d_align = big_e - small_e;
            // sticky dos bits deslocados para fora do small
            if (d_align == 0)
                sticky_align = 1'b0;
            else if (d_align >= ACCW)
                sticky_align = |small_m;
            else
                sticky_align = |(small_m & ((1 << d_align) - 1));
            small_sh = (d_align >= ACCW) ? {ACCW{1'b0}} : (small_m >> d_align);

            if (big_s == small_s) begin
                as_acc  = big_m + small_sh;
                as_sign = big_s;
            end else begin
                if (big_m >= small_sh) begin
                    as_acc  = big_m - small_sh;
                    as_sign = big_s;
                end else begin
                    as_acc  = small_sh - big_m;
                    as_sign = small_s;
                end
            end
            // injeta sticky do alinhamento no bit0
            as_acc = as_acc | {{(ACCW-1){1'b0}}, sticky_align};
            as_zero = (as_acc == {ACCW{1'b0}});
            as_big_e = big_e;
        end
    end

    // ==================================================================
    // MULT  — produto 4x4 (ambos com hidden=1 após pré-norm)
    // ==================================================================
    reg               ml_sign;
    reg               ml_zero;
    reg  [7:0]        ml_prod;
    reg  signed [5:0] ml_e_base;   // eA_r + eB_r

    always @(*) begin
        ml_sign   = signA ^ signB;
        if (zA || zB) begin
            ml_zero = 1'b1; ml_prod = 8'b0; ml_e_base = 6'sd0;
        end else begin
            ml_zero = 1'b0;
            ml_prod = mA4 * mB4;          // 4x4 = 8 bits, bit7 ou bit6 setado
            ml_e_base = eA_r + eB_r;      // expoente real base (mantissas em [1,2))
        end
    end

    // ==================================================================
    // DIV  — Caminho 2: pré-normaliza ambos (mA4/mB4 com hidden=1, eA_r/eB_r
    //        reais), quociente das mantissas com QDIV bits de fração + sticky
    //        do resto. Mesma régua larga do ADD/SUB/MULT.
    // ==================================================================
    localparam integer QDIV = `NRM_QDIV;   // bits de fração do quociente
    reg               dv_sign;
    reg               dv_zero;
    reg  [QDIV+4:0]   dv_quot;             // inteiro(+folga) + QDIV bits frac
    reg               dv_remnz;            // resto != 0 (sticky)
    reg  signed [5:0] dv_e_real0;          // eA_r - eB_r
    reg  [QDIV+4:0]   dv_num;

    always @(*) begin
        // defaults (evita latches)
        dv_sign    = signA ^ signB;
        dv_zero    = 1'b0;
        dv_quot    = {(QDIV+5){1'b0}};
        dv_remnz   = 1'b0;
        dv_e_real0 = 6'sd0;
        dv_num     = {(QDIV+5){1'b0}};
        if (zA || zB || mB4 == 4'b0) begin
            dv_zero = 1'b1;
        end else begin
            dv_num   = {mA4, {QDIV{1'b0}}};          // mA4 << QDIV
            dv_quot  = dv_num / {{(QDIV+1){1'b0}}, mB4};
            dv_remnz = (dv_num % {{(QDIV+1){1'b0}}, mB4}) != 0;
            dv_e_real0 = eA_r - eB_r;                 // expoente real base
        end
    end


    // ==================================================================
    // SAÍDA CRUA (a normalização foi movida para fp8_normalize)
    // ==================================================================
    // sinal e is_zero já selecionados pelo opcode; os barramentos crus de
    // cada operação saem em paralelo e o fp8_normalize seleciona/normaliza.
    assign exec_sign = (opcode == `OPCODE_ADD || opcode == `OPCODE_SUB) ? as_sign :
                       (opcode == `OPCODE_MULT) ? ml_sign : dv_sign;

    assign exec_is_zero = (opcode == `OPCODE_ADD || opcode == `OPCODE_SUB) ? as_zero :
                          (opcode == `OPCODE_MULT) ? ml_zero : dv_zero;

    // ADD/SUB cru
    assign exec_acc     = as_acc;
    assign exec_big_e   = as_big_e;
    // MULT cru
    assign exec_prod    = ml_prod;
    assign exec_e_base  = ml_e_base;
    // DIV cru
    assign exec_quot    = dv_quot;
    assign exec_e_div0  = dv_e_real0;
    assign exec_remnz   = dv_remnz;

endmodule
