// ======================================================================
// MÓDULO 4: fp8_normalize  (normalizador COMPARTILHADO)
// ======================================================================
// Versao enxuta: os caminhos ADD/SUB e DIV compartilham UM unico
// detector de MSB (priority encoder) + UM unico deslocador (barrel
// shifter) para levar a magnitude ao topo da regua de 16 bits. Antes
// havia dois blocos identicos em estrutura (um para o acumulador de 26b
// do add/sub, outro para o quociente do div), so diferindo em:
//   - a magnitude de entrada,
//   - o expoente-base,
//   - o offset do expoente (G+4 vs QDIV),
//   - a fonte de sticky (bits perdidos vs resto da divisao).
// Todos foram parametrizados e fundidos. O caminho MULT permanece
// separado (e trivial: sem priority encoder).
//
// Equivalencia BIT-A-BIT com a versao anterior PROVADA por SAT (yosys
// miter, 0 contra-exemplos sobre todo o espaco de entradas).
//
// Convencao de saida identica a anterior:
//   norm_sign, norm_mant_wide[15:0] ([15]=hidden), norm_exp_real (signed),
//   norm_is_zero.
// ======================================================================
`include "header_fp8.v"

module fp8_normalize (
    input  wire [`OP_WIDTH-1:0]   opcode,
    input  wire                   in_sign,
    input  wire                   in_is_zero,
    // ADD/SUB cru
    input  wire [`NRM_ACCW-1:0]   in_acc,
    input  wire signed [5:0]      in_big_e,
    // MULT cru
    input  wire [7:0]             in_prod,
    input  wire signed [5:0]      in_e_base,
    // DIV cru
    input  wire [`NRM_QDIV+4:0]   in_quot,
    input  wire signed [5:0]      in_e_div0,
    input  wire                   in_remnz,

    output wire                   norm_sign,
    output wire [15:0]            norm_mant_wide,
    output wire signed [5:0]      norm_exp_real,
    output wire                   norm_is_zero
);
    localparam integer G    = `NRM_G;
    localparam integer ACCW = `NRM_ACCW;
    localparam integer QDIV = `NRM_QDIV;

    wire is_as = (opcode == `OPCODE_ADD) || (opcode == `OPCODE_SUB);

    // ------------------------------------------------------------------
    // Selecao da magnitude/expoente/offset/sticky do caminho ativo
    //   ADD/SUB : magnitude = in_acc (26b),   ebase = in_big_e,  off = G+4
    //   DIV     : magnitude = in_quot (zext),  ebase = in_e_div0, off = QDIV
    // (MULT nao usa este bloco.)
    // ------------------------------------------------------------------
    reg  [ACCW-1:0]   mag;
    reg  signed [5:0] ebase;
    integer           off;
    reg               extra_sticky;
    // Espelha o mux final do original: sh_wide vale para TUDO que nao for
    // MULT, ou seja, add/sub para is_as e DIV como DEFAULT (inclui opcodes
    // reservados). Por isso a selecao usa is_as (nao is_dv).
    always @(*) begin
        if (is_as) begin
            mag          = in_acc;
            ebase        = in_big_e;
            off          = G + 4;
            extra_sticky = 1'b0;
        end else begin
            mag          = {{(ACCW-(QDIV+5)){1'b0}}, in_quot};
            ebase        = in_e_div0;
            off          = QDIV;
            extra_sticky = in_remnz;
        end
    end

    // ------------------------------------------------------------------
    // Normalizador compartilhado (priority encoder + barrel shifter)
    // ------------------------------------------------------------------
    reg  [15:0]       sh_wide;
    reg  signed [5:0] sh_e_real;
    integer           msb, i, e_int, shr, shl;
    reg  [ACCW-1:0]   tmp;
    reg               lost;
    // Bits altos intencionalmente nao lidos (e_int usa [5:0]; tmp usa [15:0]).
    wire _unused_nrm = &{1'b0, e_int[31:6], tmp[ACCW-1:16]};
    always @(*) begin
        sh_wide   = 16'b0;
        sh_e_real = 6'sd0;
        tmp       = {ACCW{1'b0}};
        lost      = 1'b0;
        shr       = 0;
        shl       = 0;
        e_int     = 0;

        msb = -1;
        for (i = ACCW-1; i >= 0; i = i-1)
            if (msb == -1 && mag[i]) msb = i;

        if (in_is_zero || msb < 0) begin
            sh_wide = 16'b0; sh_e_real = 6'sd0;
        end else begin
            e_int     = $signed({{26{ebase[5]}}, ebase}) + (msb - off);
            sh_e_real = e_int[5:0];
            if (msb >= 15) begin
                shr     = msb - 15;
                lost    = |(mag & ((({ACCW{1'b1}}) >> $unsigned(ACCW - shr))));
                tmp     = mag >> $unsigned(shr);
                sh_wide = tmp[15:0];
                if (lost) sh_wide[0] = sh_wide[0] | 1'b1;
            end else begin
                shl     = 15 - msb;
                sh_wide = mag[15:0] << $unsigned(shl);
            end
            // sticky extra (resto da divisao)
            if (extra_sticky) sh_wide[0] = sh_wide[0] | 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // MULT (trivial, sem priority encoder)
    // ------------------------------------------------------------------
    reg  [15:0]       ml_wide;
    reg  signed [5:0] ml_e_real;
    always @(*) begin
        if (in_is_zero) begin
            ml_wide = 16'b0; ml_e_real = 6'sd0;
        end else if (in_prod[7]) begin
            ml_e_real = in_e_base + 6'sd1;
            ml_wide   = {in_prod, 8'b0};
        end else begin
            ml_e_real = in_e_base;
            ml_wide   = {in_prod[6:0], 9'b0};
        end
    end

    // ------------------------------------------------------------------
    // Selecao final por opcode
    // ------------------------------------------------------------------
    assign norm_sign      = in_sign;
    assign norm_mant_wide = (opcode == `OPCODE_MULT) ? ml_wide : sh_wide;
    assign norm_exp_real  = (opcode == `OPCODE_MULT) ? ml_e_real : sh_e_real;
    assign norm_is_zero   = in_is_zero;

endmodule
