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
    // sticky do alinhamento do ADD/SUB. NAO e' injetado no acumulador: se
    // fosse, o deslocamento a esquerda da normalizacao (cancelamento) o
    // carregaria para dentro das posicoes de guard/round e ele passaria a
    // ser lido como um bit exato. Sai separado e o fp8_normalize o aplica
    // DEPOIS de normalizar, na posicao de sticky, junto com o remnz do DIV.
    output wire                    exec_sticky,
    // MULT cru
    output wire [7:0]              exec_prod,
    output wire signed [5:0]       exec_e_base,
    // DIV cru — a divisao das mantissas migrou para fp8_div_iter (iterativo).
    // Aqui expomos apenas os operandos pre-normalizados (mA4/mB4) e o
    // expoente-base; o quociente/remnz vem da unidade iterativa.
    output wire [3:0]              exec_mA4,
    output wire [3:0]              exec_mB4,
    output wire signed [5:0]       exec_e_div0,
    // SQRT: paridade do expoente real de A (p/ montar o radicando no iter)
    output wire                    exec_parity,
    // SCALB: expoente real de A (pre-normalizado) p/ e_real = eA_r + n
    output wire signed [5:0]       exec_eA_r
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
    localparam [5:0]   ACCW6 = `NRM_ACCW;  // mesma constante em 6 bits (comparar c/ d_align)

    // ---- CVT inteiro -> fp8 -------------------------------------------
    // Um inteiro n com MSB no bit k vale 1.xxx * 2^k. Colocando n nos bits
    // baixos do acumulador e usando ebase = off (= G+4), o fp8_normalize
    // calcula e_real = ebase + (msb - off) = msb, que e' exatamente k.
    // Assim as conversoes reaproveitam a LZC, o shifter e o fp8_round
    // inteiros, sem hardware novo de normalizacao/arredondamento.
    localparam signed [5:0] CVT_EBASE = G + 4;
    wire        is_i2f    = (opcode == `OPCODE_CVT_I2F);
    wire        is_u2f    = (opcode == `OPCODE_CVT_U2F);
    wire        is_cvt_if = is_i2f | is_u2f;
    wire [7:0]  cvt_in    = {signA, expA, mantA};        // A cru (e' um inteiro)
    wire        cvt_neg   = is_i2f & cvt_in[7];          // U2F nunca e' negativo
    wire [7:0]  cvt_mag   = cvt_neg ? (~cvt_in + 8'd1) : cvt_in;

    reg                 as_sign;
    reg                 as_zero;
    reg                 as_sticky;
    reg  [ACCW-1:0]     as_acc;            // acumulador (magnitude)
    reg  signed [5:0]   as_big_e;

    reg  signed [5:0]   big_e, small_e;
    reg                 big_s, small_s;
    reg  [ACCW-1:0]     big_m, small_m, small_sh;
    reg  [5:0]          d_align;
    reg                 sticky_align;
    // Bits de flag nao usados por este modulo (usa apenas NORMAL/SUBNORMAL).
    wire _unused_ec = &{1'b0, flagsA[6:3], flagsA[0], flagsB[6:3], flagsB[0]};

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
        as_sticky    = 1'b0;
        as_acc       = {ACCW{1'b0}};
        as_big_e     = 6'sd0;

        // seleciona maior expoente
        if (is_cvt_if) begin
            as_sign  = cvt_neg;
            as_zero  = (cvt_mag == 8'd0);
            as_acc   = {{(ACCW-8){1'b0}}, cvt_mag};      // ACCW=10 > 8
            as_big_e = CVT_EBASE;
        end else if (zA && zB) begin
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
            else if (d_align >= ACCW6)
                sticky_align = |small_m;
            else
                sticky_align = |(small_m & ((1 << d_align) - 1));
            small_sh = (d_align >= ACCW6) ? {ACCW{1'b0}} : (small_m >> d_align);

            if (big_s == small_s) begin
                // SOMA: os bits descartados so' aumentam o resultado
                // verdadeiro; representa-lo por baixo com sticky=1 ja' e'
                // a forma correta para o arredondamento.
                as_acc  = big_m + small_sh;
                as_sign = big_s;
            end else begin
                // SUBTRACAO: os bits descartados tornam o subtraendo MAIOR,
                // logo o resultado verdadeiro e' MENOR que (big - small_sh).
                // Sinalizar sticky nao basta: e' preciso tomar emprestado 1
                // ulp do acumulador. O valor exato passa a estar no intervalo
                // (as_acc, as_acc+1), que e' exatamente o que sticky=1
                // representa para o arredondador.
                if (big_m >= small_sh) begin
                    as_acc  = big_m - small_sh - {{(ACCW-1){1'b0}}, sticky_align};
                    as_sign = big_s;
                end else begin
                    as_acc  = small_sh - big_m;
                    as_sign = small_s;
                end
            end
            // sticky sai separado (aplicado pos-normalizacao, ver acima)
            as_sticky = sticky_align;
            as_zero = (as_acc == {ACCW{1'b0}}) && !sticky_align;
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
    // DIV  — apenas sinal, is_zero e expoente-base. A divisao das
    //        mantissas (quot/remnz) é feita fora, por fp8_div_iter, sobre
    //        os operandos pre-normalizados mA4/mB4 aqui expostos.
    // ==================================================================
    wire              dv_sign = signA ^ signB;
    wire              dv_zero = zA | zB;              // real path nunca (specials tratados no pre_execute)
    wire signed [5:0] dv_e_real0 = eA_r - eB_r;       // expoente real base (DIV)
    wire              is_sqrt   = (opcode == `OPCODE_SQRT);

    // ==================================================================
    // SAÍDA CRUA (a normalização foi movida para fp8_normalize)
    // ==================================================================
    // sinal e is_zero já selecionados pelo opcode; os barramentos crus de
    // cada operação saem em paralelo e o fp8_normalize seleciona/normaliza.
    // o caminho do acumulador serve ADD/SUB e tambem as conversoes int->fp8
    wire use_as_path = (opcode == `OPCODE_ADD) || (opcode == `OPCODE_SUB) || is_cvt_if;

    assign exec_sign = use_as_path ? as_sign :
                       (opcode == `OPCODE_MULT) ? ml_sign :
                       is_sqrt ? 1'b0 : dv_sign;   // SQRT: resultado sempre +

    assign exec_is_zero = use_as_path ? as_zero :
                          (opcode == `OPCODE_MULT) ? ml_zero :
                          is_sqrt ? 1'b0 : dv_zero;

    // ADD/SUB cru
    assign exec_acc     = as_acc;
    assign exec_big_e   = as_big_e;
    assign exec_sticky  = as_sticky;
    // MULT cru
    assign exec_prod    = ml_prod;
    assign exec_e_base  = ml_e_base;
    // DIV/SQRT: operandos pre-normalizados + expoente-base (quot/remnz do iter)
    assign exec_mA4     = mA4;
    assign exec_mB4     = mB4;
    //   DIV : e_div0 = eA_r - eB_r ;  SQRT : e_real/2 = eA_r >>> 1 (aritmetico)
    assign exec_e_div0  = is_sqrt ? (eA_r >>> 1) : dv_e_real0;
    assign exec_parity  = eA_r[0];
    assign exec_eA_r    = eA_r;

endmodule
