// ======================================================================
// MÓDULO 1: fp8_unpack
// Extrai sign/exp/mant e classifica o operando em flags.
//
// Formato FP8 E4M3:
//   fp[7]   = sinal
//   fp[6:3] = expoente (4 bits, bias=7)
//   fp[2:0] = mantissa (3 bits fracionários)
//
// Valores especiais:
//   Inf : exp=1111, mant=000
//   NaN : exp=1111, mant≠000
//   Zero: exp=0000, mant=000
//   Sub : exp=0000, mant≠000
// ======================================================================
`include "header_fp8.v"

module fp8_unpack (
    input  wire [7:0]              fp,
    output wire                    sign,
    output wire [3:0]              exp,
    output wire [2:0]              mant,
    output wire [`FLAG_WIDTH-1:0]  flags
);
    assign sign = fp[7];
    assign exp  = fp[6:3];
    assign mant = fp[2:0];

    wire is_inf_nan    = (exp == 4'b1111);
    wire is_nan        = is_inf_nan && (mant != 3'b000);
    wire is_inf        = is_inf_nan && (mant == 3'b000);
    wire is_zero       = (exp == 4'b0000) && (mant == 3'b000);
    wire is_subnormal  = (exp == 4'b0000) && (mant != 3'b000);
    wire is_normal     = ~(is_nan | is_inf | is_zero | is_subnormal);

    assign flags[`FLAG_SNAN]      = 1'b0;       // FP8 E4M3: sem sNaN separado
    assign flags[`FLAG_QNAN]      = is_nan;
    assign flags[`FLAG_NAN]       = is_nan;
    assign flags[`FLAG_INF]       = is_inf;
    assign flags[`FLAG_NORMAL]    = is_normal;
    assign flags[`FLAG_SUBNORMAL] = is_subnormal;
    assign flags[`FLAG_ZERO]      = is_zero;
endmodule
