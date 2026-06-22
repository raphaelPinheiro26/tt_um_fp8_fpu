// ======================================================================
// MÓDULO 4: fp8_normalize  (CAMINHO 2 — régua larga, normalização)
// ======================================================================
// Recebe o resultado CRU do fp8_execute_comb e normaliza para o topo de
// uma régua de 16 bits (bit15 = hidden), produzindo a tripla que o
// fp8_round consome: (sign, mant_wide[15:0], exp_real signed, is_zero).
//
// Esta lógica foi EXTRAÍDA do antigo fp8_execute_comb (onde a normalização
// vivia fundida com a aritmética). Agora ocupa seu próprio estágio de
// pipeline, entre o execute e o round. Os três caminhos (ADD/SUB, MULT,
// DIV) são normalizados em blocos separados e selecionados pelo opcode,
// preservando o comportamento bit-a-bit do design anterior.
//
// Convenção da saída:
//   norm_sign       – sinal do resultado (passa direto do execute)
//   norm_mant_wide  – 16 bits: [15]=hidden(1), [14:12]=mant3,
//                     [11:0]=guard/round/sticky amplo (bit0 carrega sticky)
//   norm_exp_real   – expoente REAL sinalizado (6 bits, range -18..+15)
//                     O round faz E_field = exp_real + bias.
//   norm_is_zero    – resultado exatamente zero (passa direto do execute)
//
// Entradas cruas (do fp8_execute_comb):
//   ADD/SUB : in_acc (NRM_ACCW bits, sticky no bit0), in_big_e
//   MULT    : in_prod (8 bits), in_e_base
//   DIV     : in_quot (NRM_QDIV+5 bits), in_e_div0, in_remnz
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

    // ==================================================================
    // Normalização para a régua de 16 bits (bit15 = hidden)
    // ==================================================================
    // Função: dada uma magnitude e a posição do seu MSB, desloca para que
    // o MSB fique no bit15; injeta sticky no bit0 se descartar bits.
    // Como Verilog não tem "bit_length" direto, calculamos por prioridade.

    // ---- normalização do resultado ADD/SUB ----
    reg  [15:0]       as_wide;
    reg  signed [5:0] as_e_real;
    integer           as_msb;
    integer           as_e_int;
    integer           i;
    reg  [ACCW-1:0]   as_tmp;
    reg               as_lost;
    integer           as_shr;        // shift-right (>=0; $unsigned no uso)
    integer           as_shl;        // shift-left  (>=0; $unsigned no uso)
    always @(*) begin
        // defaults (evita latches): toda variável recebe valor em todo caminho
        as_wide   = 16'b0;
        as_e_real = 6'sd0;
        as_tmp    = {ACCW{1'b0}};
        as_lost   = 1'b0;
        as_shr    = 0;
        as_shl    = 0;
        as_e_int  = 0;     // default explicito -> sem latch (so usado no ramo else)

        // encontra MSB do acumulador
        as_msb = -1;
        for (i = ACCW-1; i >= 0; i = i-1)
            if (as_msb == -1 && in_acc[i]) as_msb = i;

        if (in_is_zero || as_msb < 0) begin
            as_wide = 16'b0; as_e_real = 6'sd0;
        end else begin
            // e_real = big_e + (msb - (G+4)). Conta em integer, trunca p/ 6 bits.
            as_e_int  = in_big_e + (as_msb - (G + 4));
            as_e_real = as_e_int[5:0];
            if (as_msb >= 15) begin
                as_shr  = as_msb - 15;                  // 0..10
                as_lost = |(in_acc & ((({ACCW{1'b1}}) >> $unsigned(ACCW - as_shr))));
                as_tmp  = in_acc >> $unsigned(as_shr);
                as_wide = as_tmp[15:0];
                if (as_lost) as_wide[0] = as_wide[0] | 1'b1;
            end else begin
                as_shl  = 15 - as_msb;                  // 1..15
                as_wide = in_acc[15:0] << $unsigned(as_shl);
            end
        end
    end

    // ---- normalização do resultado MULT ----
    reg  [15:0]       ml_wide;
    reg  signed [5:0] ml_e_real;
    always @(*) begin
        if (in_is_zero) begin
            ml_wide = 16'b0; ml_e_real = 6'sd0;
        end else if (in_prod[7]) begin
            // produto em [2,4): hidden em bit7 -> e_real = base + (7-6)=+1
            ml_e_real = in_e_base + 6'sd1;
            ml_wide   = {in_prod, 8'b0};            // bit7 -> bit15
        end else begin
            // produto em [1,2): hidden em bit6 -> e_real = base + 0
            ml_e_real = in_e_base;
            ml_wide   = {in_prod[6:0], 9'b0};       // bit6 -> bit15
        end
    end

    // ---- normalização do resultado DIV (régua larga, Caminho 2) ----
    // in_quot tem QDIV+5 bits (<=15 bits úteis), MSB sempre < 15, então o
    // resultado sempre cabe num shift-left para pôr o MSB no bit15.
    reg  [15:0]       dv_wide;
    reg  signed [5:0] dv_e_real;
    integer           dvj, dv_msb;
    integer           dv_e_int;
    integer           dv_shl;        // shift-left (>=0; $unsigned no uso)
    always @(*) begin
        // defaults (evita latches)
        dv_wide   = 16'b0;
        dv_e_real = 6'sd0;
        dv_shl    = 0;
        dv_e_int  = 0;     // default explicito -> sem latch (so usado no ramo else)
        dv_msb    = -1;
        for (dvj = QDIV+4; dvj >= 0; dvj = dvj-1)
            if (dv_msb == -1 && in_quot[dvj]) dv_msb = dvj;
        if (in_is_zero || dv_msb < 0) begin
            dv_wide = 16'b0; dv_e_real = 6'sd0;
        end else begin
            // quociente = in_quot / 2^QDIV, em [0.5,2). MSB em dv_msb.
            dv_e_int  = in_e_div0 + (dv_msb - QDIV);
            dv_e_real = dv_e_int[5:0];
            // põe MSB no bit15 (in_quot estendido a 16 bits), shift unsigned
            dv_shl  = 15 - dv_msb;                     // 1..15
            dv_wide = ({1'b0, in_quot}) << $unsigned(dv_shl);
            // sticky do resto da divisão no bit0
            if (in_remnz) dv_wide[0] = dv_wide[0] | 1'b1;
        end
    end

    // ==================================================================
    // SELEÇÃO FINAL (por opcode)
    // ==================================================================
    assign norm_sign = in_sign;

    assign norm_mant_wide = (opcode == `OPCODE_ADD || opcode == `OPCODE_SUB) ? as_wide :
                            (opcode == `OPCODE_MULT) ? ml_wide : dv_wide;

    assign norm_exp_real  = (opcode == `OPCODE_ADD || opcode == `OPCODE_SUB) ? as_e_real :
                            (opcode == `OPCODE_MULT) ? ml_e_real : dv_e_real;

    assign norm_is_zero = in_is_zero;

endmodule
