#!/usr/bin/env python3
# ======================================================================
# fp8_common.py — Utilidades do formato FP8 E4M3 (bias=7).
#
# Layout do byte:  [7]=sinal  [6:3]=expoente(4b)  [2:0]=mantissa(3b)
#   Zero       : exp=0000 mant=000
#   Subnormais : exp=0000 mant!=000  -> mant * 2^-9
#   Normais    : exp=0001..1110      -> (1 + mant/8) * 2^(exp-7)
#   Infinito   : exp=1111 mant=000
#   NaN        : exp=1111 mant!=000
#
# Fornece:
#   unpack(fp)            -> (sign, exp, mant, is_special_dict)
#   is_special(fp)        -> True se exp==1111 (inf/nan)
#   fp8_to_fraction(fp)   -> valor EXATO como Fraction (None se inf/nan)
#
# Constantes do formato em um só lugar para os demais scripts importarem.
# ======================================================================
from fractions import Fraction

BIAS = 7
EMIN = 1 - BIAS          # -6  (menor expoente normal, valor real)
MANT_W = 3
EXP_W = 4

# opcodes (devem casar com header_fp8.v)
OP_ADD, OP_SUB, OP_MULT, OP_DIV = 0, 1, 2, 3
OP_NAMES = {OP_ADD: "ADD", OP_SUB: "SUB", OP_MULT: "MULT", OP_DIV: "DIV"}

# modos de arredondamento
RM_NEAREST, RM_ZERO, RM_UP, RM_DOWN, RM_ODD = 0, 1, 2, 3, 4
RM_NAMES = {RM_NEAREST: "NEAR", RM_ZERO: "ZERO", RM_UP: "UP",
            RM_DOWN: "DOWN", RM_ODD: "ODD"}

CANONICAL_NAN = 0b0_1111_001     # quiet NaN mínimo
PINF = 0b0_1111_000
NINF = 0b1_1111_000


def unpack(fp):
    """Extrai campos do byte FP8. Retorna (sign, exp, mant)."""
    fp &= 0xFF
    return (fp >> 7) & 1, (fp >> 3) & 0xF, fp & 0x7


def is_special(fp):
    """True se o código é Inf ou NaN (exp==1111)."""
    return ((fp >> 3) & 0xF) == 0xF


def is_nan(fp):
    return is_special(fp) and (fp & 0x7) != 0


def is_inf(fp):
    return is_special(fp) and (fp & 0x7) == 0


def fp8_to_fraction(fp):
    """Valor matemático EXATO do código FP8 como Fraction.
    Retorna None para Inf/NaN. Subnormais e zero tratados corretamente."""
    sign, exp, mant = unpack(fp)
    s = -1 if sign else 1
    if exp == 0xF:
        return None                      # inf / nan
    if exp == 0:
        # subnormal (ou zero): mant * 2^(1-bias) * 2^-MANT_W = mant * 2^-9
        return Fraction(s * mant, 1) * Fraction(1, 2 ** (MANT_W + BIAS - 1))
    # normal: (1 + mant/8) * 2^(exp-7)
    return s * Fraction(8 + mant, 8) * (Fraction(2) ** (exp - BIAS))


# maior finito positivo (exp=1110, mant=111) — útil p/ overflow
MAXFIN_CODE = 0b0_1110_111
MAXFIN_VAL = fp8_to_fraction(MAXFIN_CODE)            # 240
ULP_TOP = Fraction(2) ** (0xE - BIAS - MANT_W)       # passo do último binade (16)


if __name__ == "__main__":
    # auto-checagem rápida dos valores de referência
    checks = {0x00: 0, 0x01: Fraction(1, 512), 0x38: 1, 0x40: 2,
              0x77: 240, 0x70: 128}
    for code, exp_val in checks.items():
        got = fp8_to_fraction(code)
        assert got == exp_val, (hex(code), got, exp_val)
    print("fp8_common: valores de referência OK")
    print(f"  maior finito = 0x{MAXFIN_CODE:02X} = {float(MAXFIN_VAL)}")
    print(f"  menor subnormal = 0x01 = {float(fp8_to_fraction(0x01))}")
