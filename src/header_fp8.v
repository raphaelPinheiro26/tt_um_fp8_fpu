// ======================================================================
// FPU 8-bit - Header Definition File (FP8 E4M3)
// ======================================================================
//
// DESCRIPTION:
// Header para FPU de 8 bits no formato E4M3:
//   [sinal 1b][expoente 4b][mantissa 3b]
//
// FORMATO FP8 E4M3:
//   - Bit 7     : sinal (0 = positivo, 1 = negativo)
//   - Bits 6:3  : expoente (bias = 7, ou seja, 2^(4-1)-1 = 7)
//   - Bits 2:0  : mantissa (3 bits fracionários + hidden bit implícito)
//
// VALORES ESPECIAIS:
//   Zero       : exp=0000, mant=000  → ±0
//   Subnormais : exp=0000, mant≠000  → ±mant × 2^(1-bias) = ±mant × 2^(-6)
//   Normais    : exp=0001..1110      → ±1.mant × 2^(exp-bias)
//   Infinito   : exp=1111, mant=000  → ±Inf
//   NaN        : exp=1111, mant≠000  → NaN (quiet)
//
// RANGE (normais):
//   Menor normal positivo : exp=0001, mant=000 → 1.0 × 2^(-6)  ≈ 0.015625
//   Maior normal positivo : exp=1110, mant=111 → 1.875 × 2^7   = 240.0
//   Subnormal mínimo      : exp=0000, mant=001 → 0.001 × 2^(-6) ≈ 0.001953
//
// AUTOR: Adaptado do design FP4 E2M1 de Raphael Lopes Pinheiro
// DATA: 2026
// ======================================================================

`ifndef HEADER_FP8_V
`define HEADER_FP8_V

// ======================================================================
// DIMENSÕES DO FORMATO FP8 E4M3
// ======================================================================
`define WIDTH         8      // Total de bits
`define EXP_WIDTH     4      // Bits de expoente
`define MANT_WIDTH    3      // Bits de mantissa (sem hidden bit)

// Bias = 2^(EXP_WIDTH-1) - 1 = 7
`define BIAS          4'b0111

// ======================================================================
// LARGURAS DOS VETORES DE CONTROLE
// ======================================================================
`define FLAG_WIDTH    7
`define EXC_WIDTH     5
`define OP_WIDTH      5
`define RD_WIDTH      4

// ======================================================================
// POSIÇÕES DOS FLAGS DE CLASSIFICAÇÃO
// ======================================================================
`define FLAG_SNAN       6      // Signaling NaN
`define FLAG_QNAN       5      // Quiet NaN
`define FLAG_NAN        4      // Qualquer NaN
`define FLAG_INF        3      // Infinito
`define FLAG_NORMAL     2      // Número normal
`define FLAG_SUBNORMAL  1      // Subnormal
`define FLAG_ZERO       0      // Zero

// ======================================================================
// OPCODES
// ======================================================================
`define OPCODE_ADD      5'b00000
`define OPCODE_SUB      5'b00001
`define OPCODE_MULT     5'b00010
`define OPCODE_DIV      5'b00011
`define OPCODE_SQRT     5'b00100
`define OPCODE_MIN      5'b00101
`define OPCODE_MAX      5'b00110
`define OPCODE_ABS      5'b00111
`define OPCODE_CLASSIFY 5'b01000
`define OPCODE_COMPARE  5'b01001
`define OPCODE_SCALB    5'b01010
`define OPCODE_ROUNDINT 5'b01011
`define OPCODE_NEG      5'b01100    // negate(A): copia A com o sinal invertido
`define OPCODE_COPYSIGN 5'b01101    // copySign(A,B): magnitude de A, sinal de B
// Conversoes inteiro <-> fp8. Semantica RISC-V FCVT: arredonda pelo rm e
// DEPOIS checa a faixa, saturando no extremo com INVALID. A IEEE-754 deixa
// esse resultado nao especificado; fixar o valor do RISC-V custa ~20 celulas
// e torna o modelo de referencia total (toda entrada tem saida definida).
// Todas sao UNARIAS em A.
`define OPCODE_CVT_F2I  5'b01110    // fp8   -> int8   (satura [-128,127])
`define OPCODE_CVT_F2U  5'b01111    // fp8   -> uint8  (satura [0,255])
`define OPCODE_CVT_I2F  5'b10000    // int8  -> fp8    (nunca estoura)
`define OPCODE_CVT_U2F  5'b10001    // uint8 -> fp8    (255 > 240: pode estourar)

// ======================================================================
// MODOS DE ARREDONDAMENTO
// ======================================================================
`define ROUND_NEAREST   3'b000    // Mais próximo, empate para par
`define ROUND_ZERO      3'b001    // Trunca (em direção a zero)
`define ROUND_UP        3'b010    // Em direção a +∞
`define ROUND_DOWN      3'b011    // Em direção a -∞
`define ROUND_ODD       3'b100    // Mais próximo, empate para ímpar

// ======================================================================
// FLAGS DE EXCEÇÃO IEEE 754
// ======================================================================
`define EXC_INVALID_OP  4      // Operação inválida
`define EXC_DIV_ZERO    3      // Divisão por zero
`define EXC_OVERFLOW    2      // Overflow
`define EXC_UNDERFLOW   1      // Underflow
`define EXC_INEXACT     0      // Resultado inexato (arredondado)

// ======================================================================
// LIMITES DO EXPOENTE (para detecção de overflow/underflow)
// ======================================================================
`define EXP_MAX         4'b1110   // Maior expoente normal (14)
`define EXP_INF_NAN     4'b1111   // Expoente reservado para Inf/NaN
`define EXP_ZERO_SUB    4'b0000   // Expoente zero/subnormal

// Expoente sinalizado máximo representável (valor real = EXP_MAX - BIAS = 7)
`define EXP_S_MAX       5'sd7
// Expoente sinalizado mínimo normal (valor real = 1 - BIAS = -6)
`define EXP_S_MIN_NORM  5'sd-6

// ======================================================================
// PARÂMETROS DA RÉGUA LARGA (compartilhados entre execute e normalize)
// ======================================================================
// Estes parâmetros definem as larguras dos barramentos crus que o
// fp8_execute_comb entrega ao fp8_normalize. Mantê-los aqui garante que
// os dois módulos (e o empacotamento na pipeline) concordem.
//
//   NRM_G    : guarda ampla usada no alinhamento do ADD/SUB
//   NRM_ACCW : largura do acumulador ADD/SUB = 4 + NRM_G + 2
//   NRM_QDIV : bits de fração do quociente da divisão
//                (o quociente cru tem NRM_QDIV+5 bits)
//
// NRM_G era 20, dimensionado para que o alinhamento do ADD/SUB fosse
// SEMPRE exato (d_align maximo = 16). Isso tornava o sticky codigo morto:
// nenhum bit era jamais descartado. Com o sticky corrigido — saida
// separada do fp8_execute_comb, aplicada DEPOIS da normalizacao, e
// entrando como BORROW no caminho de subtracao — o acumulador foi
// reduzido ao piso. Equivalencia bit-a-bit verificada exaustivamente:
// ADD/SUB 655.360 vetores e MULT 327.680, nos 5 modos de arredondamento.
//
// PISO: fp8_normalize faz mag = {{(ACCW-(QDIV+5)){1'b0}}, in_quot}, logo
//       NRM_ACCW >= NRM_QDIV+5 = 10. NRM_G=4 ja' esta' nesse piso; nao
//       reduza mais sem antes reduzir NRM_QDIV.
// NRM_MW : largura do barramento pre-arredondamento (norm_mant_wide).
//   Layout: [MW-1]=hidden, [MW-2:MW-4]=mant3, [MW-5]=guard, [MW-6]=round,
//           [MW-7:0]=campo de sticky.
//
//   Era 16 fixo. O conteudo util sao 7 bits (hidden + 3 de mantissa +
//   guard + round + sticky); os 9 bits restantes existiam apenas para
//   sobreviver ao deslocamento de desnormalizacao no fp8_round. Com o
//   sticky OR-reduzido corretamente esse campo pode ser minimo.
//
//   PISO: o MULT injeta seu produto de 8 bits no topo do barramento
//         (fp8_normalize: ml_wide = {in_prod, ...}), logo NRM_MW >= 8.
//         Este e' o unico barramento REGISTRADO destes tres parametros:
//         reduzi-lo economiza flops no RA do pipeline elastico.
`define NRM_MW    8

`define NRM_G     4
`define NRM_ACCW  10
`define NRM_QDIV  5

`endif // HEADER_FP8_V
