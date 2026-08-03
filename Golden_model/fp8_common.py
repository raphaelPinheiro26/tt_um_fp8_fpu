#!/usr/bin/env python3
# ======================================================================
# fp8_common.py — FP8 E4M3 format utilities (bias = 7).
#
# Byte layout:  [7]=sign  [6:3]=exponent(4b)  [2:0]=mantissa(3b)
#   Zero        : exp=0000 mant=000
#   Subnormals  : exp=0000 mant!=000  -> mant * 2^-9
#   Normals     : exp=0001..1110      -> (1 + mant/8) * 2^(exp-7)
#   Infinity    : exp=1111 mant=000
#   NaN         : exp=1111 mant!=000
#
# Provides:
#   unpack(fp)            -> (sign, exp, mant)
#   is_special(fp)        -> True if exp==1111 (inf/nan)
#   fp8_to_fraction(fp)   -> EXACT value as a Fraction (None for inf/nan)
#
# Format constants in one place for the other scripts to import.
# ======================================================================
from fractions import Fraction

BIAS = 7
EMIN = 1 - BIAS          # -6  (smallest normal exponent, real value)
MANT_W = 3
EXP_W = 4

# opcodes (must match header_fp8.v)
OP_ADD, OP_SUB, OP_MULT, OP_DIV, OP_SQRT = 0, 1, 2, 3, 4
OP_MIN, OP_MAX, OP_ABS, OP_CLASSIFY, OP_COMPARE, OP_SCALB, OP_ROUNDINT = 5, 6, 7, 8, 9, 10, 11
OP_NEG, OP_COPYSIGN = 12, 13
OP_NAMES = {OP_ADD: "ADD", OP_SUB: "SUB", OP_MULT: "MULT", OP_DIV: "DIV", OP_SQRT: "SQRT",
            OP_MIN: "MIN", OP_MAX: "MAX", OP_ABS: "ABS", OP_CLASSIFY: "CLASSIFY",
            OP_COMPARE: "COMPARE", OP_SCALB: "SCALB", OP_ROUNDINT: "ROUNDINT",
            OP_NEG: "NEG", OP_COPYSIGN: "COPYSIGN"}

# rounding modes
RM_NEAREST, RM_ZERO, RM_UP, RM_DOWN, RM_ODD = 0, 1, 2, 3, 4
RM_NAMES = {RM_NEAREST: "NEAR", RM_ZERO: "ZERO", RM_UP: "UP",
            RM_DOWN: "DOWN", RM_ODD: "ODD"}

CANONICAL_NAN = 0b0_1111_001     # minimal quiet NaN
PINF = 0b0_1111_000
NINF = 0b1_1111_000


def unpack(fp):
    """Extract the FP8 byte fields. Returns (sign, exp, mant)."""
    fp &= 0xFF
    return (fp >> 7) & 1, (fp >> 3) & 0xF, fp & 0x7


def is_special(fp):
    """True if the code is Inf or NaN (exp==1111)."""
    return ((fp >> 3) & 0xF) == 0xF


def is_nan(fp):
    return is_special(fp) and (fp & 0x7) != 0


def is_inf(fp):
    return is_special(fp) and (fp & 0x7) == 0


def fp8_to_fraction(fp):
    """EXACT mathematical value of the FP8 code as a Fraction.
    Returns None for Inf/NaN. Subnormals and zero handled correctly."""
    sign, exp, mant = unpack(fp)
    s = -1 if sign else 1
    if exp == 0xF:
        return None                      # inf / nan
    if exp == 0:
        # subnormal (or zero): mant * 2^(1-bias) * 2^-MANT_W = mant * 2^-9
        return Fraction(s * mant, 1) * Fraction(1, 2 ** (MANT_W + BIAS - 1))
    # normal: (1 + mant/8) * 2^(exp-7)
    return s * Fraction(8 + mant, 8) * (Fraction(2) ** (exp - BIAS))


# largest positive finite (exp=1110, mant=111) — useful for overflow
MAXFIN_CODE = 0b0_1110_111
MAXFIN_VAL = fp8_to_fraction(MAXFIN_CODE)            # 240
ULP_TOP = Fraction(2) ** (0xE - BIAS - MANT_W)       # step of the last binade (16)


if __name__ == "__main__":
    # quick self-check of reference values
    checks = {0x00: 0, 0x01: Fraction(1, 512), 0x38: 1, 0x40: 2,
              0x77: 240, 0x70: 128}
    for code, exp_val in checks.items():
        got = fp8_to_fraction(code)
        assert got == exp_val, (hex(code), got, exp_val)
    print("fp8_common: reference values OK")
    print(f"  largest finite = 0x{MAXFIN_CODE:02X} = {float(MAXFIN_VAL)}")
    print(f"  smallest subnormal = 0x01 = {float(fp8_to_fraction(0x01))}")
