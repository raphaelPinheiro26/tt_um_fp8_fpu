#!/usr/bin/env python3
# ======================================================================
# fp8_math.py — PURELY MATHEMATICAL model of the FP8 E4M3 FPU.
#
# Unlike fp8_golden_c2 / fp8_model_c2 (which mirror the RTL datapath:
# prenorm, 16-bit wide ruler, sticky, G=20, QDIV=10), this module works
# ONLY WITH VALUE:
#
#   1) special cases (NaN / Inf / Zero) resolved at the value level;
#   2) the finite result is the EXACT value  fA op fB  as a Fraction
#      (with no intermediate floating-point error);
#   3) that exact value is rounded to FP8 (built-in IEEE-like rounder)
#      and the IEEE flags/exceptions are derived from the result.
#
# It is the mathematical SPECIFICATION that the RTL is audited against.
# It was verified identical to fp8_golden_c2 across all 1,310,720 cases
# (256 x 256 x 4 ops x 5 modes), returning the same triple.
#
# Depends ONLY on fp8_common (self-contained).
#
# Flag/exc positions follow header_fp8.v:
#   FLAG: SNAN6 QNAN5 NAN4 INF3 NORMAL2 SUBNORMAL1 ZERO0
#   EXC : INVALID4 DIVZERO3 OVERFLOW2 UNDERFLOW1 INEXACT0
#
# API:
#   fp8_math(A, B, opcode, rm) -> (result, flags, exceptions)
# ======================================================================
from fractions import Fraction
from fp8_common import (unpack, is_special, is_nan, is_inf, fp8_to_fraction,
                        OP_ADD, OP_SUB, OP_MULT, OP_DIV, OP_SQRT,
                        OP_MIN, OP_MAX, OP_ABS, OP_CLASSIFY, OP_COMPARE,
                        OP_SCALB, OP_ROUNDINT, OP_NEG, OP_COPYSIGN,
                        OP_CVT_F2I, OP_CVT_F2U, OP_CVT_I2F, OP_CVT_U2F,
                        INT8_MIN, INT8_MAX, UINT8_MIN, UINT8_MAX,
                        RM_NEAREST, RM_ZERO, RM_UP, RM_DOWN, RM_ODD,
                        CANONICAL_NAN, MAXFIN_VAL, ULP_TOP)

# --- flag bits (result classification) ---
F_SNAN, F_QNAN, F_NAN, F_INF, F_NORMAL, F_SUBNORMAL, F_ZERO = 6, 5, 4, 3, 2, 1, 0
# --- IEEE exception bits ---
E_INVALID, E_DIVZERO, E_OVERFLOW, E_UNDERFLOW, E_INEXACT = 4, 3, 2, 1, 0


def _b(i):
    return 1 << i


# ----------------------------------------------------------------------
# IEEE-LIKE ROUNDER (built-in) — rounds an exact Fraction to an FP8 code
# in any of the 5 modes. Works over the grid of representable finites;
# overflow goes to Inf according to the mode.
# ----------------------------------------------------------------------
_POS = sorted(                                  # (value, code) of finites >= 0
    (fp8_to_fraction(c), c)
    for c in range(0x80)
    if not is_special(c) and fp8_to_fraction(c) is not None
       and fp8_to_fraction(c) >= 0
)
_HALFWAY = MAXFIN_VAL + ULP_TOP / 2             # midpoint to the virtual "next"


def _ideal(value, rm):
    """Round an exact Fraction to FP8 in mode rm. value may be 0."""
    if value == 0:
        return 0x00
    sign = 0 if value > 0 else 1
    v = abs(value)

    # overflow (above the largest finite)
    if v > MAXFIN_VAL:
        mx = (sign << 7) | 0x77
        inf = (sign << 7) | (0xF << 3)
        if rm == RM_ZERO or rm == RM_ODD:
            return mx
        if rm == RM_UP:
            return inf if sign == 0 else mx
        if rm == RM_DOWN:
            return inf if sign == 1 else mx
        return inf if v >= _HALFWAY else mx     # NEAREST: tie and above -> Inf

    # neighbours lo <= v <= hi on the representable grid
    lo = hi = None
    for val, code in _POS:
        if val <= v:
            lo = (val, code)
        if val >= v and hi is None:
            hi = (val, code)

    if lo and lo[0] == v:                       # exactly representable
        return (sign << 7) | lo[1]

    lv, lc = lo
    hv, hc = hi
    if rm == RM_ZERO:
        pick = lc
    elif rm == RM_UP:
        pick = hc if sign == 0 else lc
    elif rm == RM_DOWN:
        pick = lc if sign == 0 else hc
    elif rm == RM_NEAREST:
        dl, dh = v - lv, hv - v
        if dl < dh:
            pick = lc
        elif dh < dl:
            pick = hc
        else:                                   # tie -> even
            pick = lc if (lc & 1) == 0 else hc
    else:                                       # RM_ODD: inexact picks LSB=1
        if (lc & 1) == 1:
            pick = lc
        elif (hc & 1) == 1:
            pick = hc
        else:
            pick = lc
    return (sign << 7) | pick


# ----------------------------------------------------------------------
# SPECIAL CASES — resolved by VALUE (NaN/Inf/Zero), not by datapath.
# Returns (result, flags, exc), or None for the normal finite path.
# ----------------------------------------------------------------------
def _special(A, B, op, rm):
    sA, eA, mA = unpack(A)
    sB, eB, mB = unpack(B)
    a_nan, b_nan = is_nan(A), is_nan(B)
    a_inf, b_inf = is_inf(A), is_inf(B)
    a_zero = (eA == 0 and mA == 0)
    b_zero = (eB == 0 and mB == 0)
    a_sub = (eA == 0 and mA != 0)
    b_sub = (eB == 0 and mB != 0)
    # effective sign of B: subtraction = addition with B negated
    sBx = (1 - sB) if op == OP_SUB else sB

    INVALID = (CANONICAL_NAN, _b(F_NAN) | _b(F_QNAN), _b(E_INVALID))

    # --- input NaN: propagate the operand (quiet), signal invalid ---
    if a_nan or b_nan:
        res = ((sA << 7) | (0xF << 3) | mA) if a_nan else ((sB << 7) | (0xF << 3) | mB)
        return res, _b(F_NAN) | _b(F_QNAN), _b(E_INVALID)

    # --- Inf op Inf ---
    if a_inf and b_inf:
        if op == OP_MULT:
            return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), 0
        if op == OP_DIV:                                # Inf/Inf
            return INVALID
        if (op == OP_SUB and sA == sB) or (op == OP_ADD and sA != sB):
            return INVALID                             # Inf - Inf
        return (sA << 7) | (0xF << 3), _b(F_INF), 0    # Inf + Inf (same sign)

    # --- Inf op finite  /  finite op Inf ---
    if a_inf or b_inf:
        if op == OP_MULT:
            if (a_inf and b_zero) or (b_inf and a_zero):
                return INVALID                         # Inf * 0
            return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), 0
        if op == OP_DIV:
            if a_inf:                                  # Inf / finite = Inf
                return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), 0
            return ((sA ^ sB) << 7), _b(F_ZERO), 0     # finite / Inf = 0
        res = (sA << 7) | (0xF << 3) if a_inf else (sBx << 7) | (0xF << 3)
        return res, _b(F_INF), 0                       # Inf +/- finite = +/-Inf

    # --- 0 op 0 ---
    if a_zero and b_zero:
        if op == OP_DIV:                               # 0/0
            return INVALID
        if op == OP_MULT:
            return ((sA ^ sB) << 7), _b(F_ZERO), 0
        if op == OP_SUB:
            rsz = 1 if rm == RM_DOWN else 0            # 0-0 = +0 (-0 in DOWN)
        else:
            rsz = sA & sBx                             # 0+0 = -0 only if both -0
        return (rsz << 7), _b(F_ZERO), 0

    # --- 0 op finite ---
    if a_zero:
        if op in (OP_MULT, OP_DIV):
            return ((sA ^ sB) << 7), _b(F_ZERO), 0     # 0*x=+-0 ; 0/x=+-0
        res = (sBx << 7) | (eB << 3) | mB              # 0 +/- B = +/-B
        return res, (_b(F_SUBNORMAL) if b_sub else _b(F_NORMAL)), 0

    # --- finite op 0 ---
    if b_zero:
        if op == OP_MULT:
            return ((sA ^ sB) << 7), _b(F_ZERO), 0
        if op == OP_DIV:                               # x/0 = +-Inf
            return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), _b(E_DIVZERO)
        res = (sA << 7) | (eA << 3) | mA               # A +/- 0 = A
        return res, (_b(F_SUBNORMAL) if a_sub else _b(F_NORMAL)), 0

    return None                                        # normal finite path


# ----------------------------------------------------------------------
# VALUE-LEVEL ROUNDING — takes the exact value (Fraction) and the mode,
# returns (result, flags, exc). Flags come from classifying the resulting
# byte; exceptions (INEXACT/OVERFLOW/UNDERFLOW) come from comparing the
# exact value against the rounded value.
# ----------------------------------------------------------------------
def _round_value(v, rm):
    # exact cancellation (e.g. x - x): +0, or -0 in DOWN mode
    if v == 0:
        return (0x80 if rm == RM_DOWN else 0x00), _b(F_ZERO), 0

    byte = _ideal(v, rm)                # IEEE-like rounder (built-in)
    s, e, m = unpack(byte)

    # overflow to Infinity (above the largest finite, per the mode)
    if e == 0xF and m == 0:
        return byte, _b(F_INF), _b(E_OVERFLOW) | _b(E_INEXACT)

    rv = fp8_to_fraction(byte)          # exact value of the rounded code
    inexact = (rv != v)
    exc = _b(E_INEXACT) if inexact else 0

    if e == 0 and m == 0:               # result became zero
        flags = _b(F_ZERO)
        if inexact:                     # non-zero value that collapsed to 0 => underflow
            exc |= _b(E_UNDERFLOW)
    elif e == 0:                        # subnormal
        flags = _b(F_SUBNORMAL)
    else:                               # normal (includes saturation at largest finite)
        flags = _b(F_NORMAL)
    return byte, flags, exc


# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# SQRT (unaria em A) — raiz corretamente arredondada, por comparacao de
# QUADRADOS (exata em Fraction). Resultado sempre positivo; negativos e
# -Inf viram NaN + NV; +-0 -> +-0 ; +Inf -> +Inf ; NaN propaga (sem NV).
# ----------------------------------------------------------------------
_SQRT_POS = sorted((fp8_to_fraction(c), c) for c in range(0x80)
                   if not is_special(c) and fp8_to_fraction(c) is not None
                      and fp8_to_fraction(c) >= 0)

def _classify_flags(code):
    s, e, m = unpack(code); fl = 0
    if e == 0xF and m != 0: fl |= _b(4) | _b(5)
    elif e == 0xF and m == 0: fl |= _b(3)
    elif e == 0 and m == 0: fl |= _b(0)
    elif e == 0 and m != 0: fl |= _b(1)
    else: fl |= _b(2)
    return fl

def fp8_sqrt(A, rm):
    s, e, m = unpack(A)
    if is_nan(A):
        return ((s << 7) | (0xF << 3) | m), _b(4) | _b(5), 0
    if is_inf(A):
        if s == 0:
            return (0xF << 3), _b(3), 0
        return CANONICAL_NAN, _b(4) | _b(5), _b(4)
    x = fp8_to_fraction(A)
    if x == 0:
        return ((s << 7) | 0x00), _b(0), 0
    if x < 0:
        return CANONICAL_NAN, _b(4) | _b(5), _b(4)
    lo = hi = None
    for val, code in _SQRT_POS:
        if val * val <= x: lo = (val, code)
        if val * val >= x and hi is None: hi = (val, code)
    lv, lc = lo; hv, hc = hi
    if lv * lv == x:
        return ((0 << 7) | lc), _classify_flags(lc), 0
    if rm == RM_ZERO:   res = lc
    elif rm == RM_UP:   res = hc
    elif rm == RM_DOWN: res = lc
    elif rm == RM_NEAREST:
        mid = (lv + hv) / 2; m2 = mid * mid
        res = lc if x < m2 else (hc if x > m2 else (lc if (lc & 1) == 0 else hc))
    else:  # RM_ODD
        res = lc if (lc & 1) == 1 else (hc if (hc & 1) == 1 else lc)
    return res, _classify_flags(res), _b(0)



# ----------------------------------------------------------------------
# CLUSTER DE OPS "BARATAS": MIN/MAX (2019), ABS, CLASSIFY, COMPARE,
# SCALB, ROUNDINT. Encodings casam com o RTL (fp8_direct_ops / SCALB).
# ----------------------------------------------------------------------
import math as _math
CANON_NAN = 0b0_1111_001

def _cflags(c):
    s, e, m = unpack(c); f = 0
    if e == 0xF and m != 0: f |= (1 << 4) | (1 << 5)
    elif e == 0xF:          f |= (1 << 3)
    elif e == 0 and m == 0: f |= (1 << 0)
    elif e == 0:            f |= (1 << 1)
    else:                   f |= (1 << 2)
    return f

def _oval(x):
    """Valor comparavel: None p/ NaN, +-inf p/ Inf, Fraction senao."""
    if is_nan(x): return None
    if is_inf(x):
        s, _, _ = unpack(x); return _math.inf * (-1 if s else 1)
    return fp8_to_fraction(x)

def fp8_abs(A):
    r = A & 0x7F
    return r, _cflags(r), 0

def fp8_neg(A):
    # negate(A): inverte o bit de sinal (inclusive +-0, +-Inf, NaN). Sem excecoes.
    r = (A ^ 0x80) & 0xFF
    return r, _cflags(r), 0

def fp8_copysign(A, B):
    # copySign(A,B): magnitude/payload de A com o sinal de B. Sem excecoes.
    r = (A & 0x7F) | (B & 0x80)
    return r, _cflags(r), 0

def fp8_classify(A):
    s, e, m = unpack(A)
    if e == 0xF and m != 0: cls = 1
    elif e == 0xF:          cls = 2 if s else 9
    elif e == 0 and m == 0: cls = 5 if s else 6
    elif e == 0:            cls = 4 if s else 7
    else:                   cls = 3 if s else 8
    return cls, 0, 0

def fp8_compare(A, B):
    if is_nan(A) or is_nan(B):
        return 0b1000, 0, 0                       # unordered
    va, vb = _oval(A), _oval(B)
    lt, eq, gt = int(va < vb), int(va == vb), int(va > vb)
    return (gt << 2) | (eq << 1) | lt, 0, 0

def _minmax(A, B, is_min):
    sa, _, _ = unpack(A); sb, _, _ = unpack(B)
    if is_nan(A) or is_nan(B):
        return CANON_NAN, _cflags(CANON_NAN), 0   # 2019: NaN propaga
    va, vb = _oval(A), _oval(B)
    if va == 0 and vb == 0:
        r = ((sa | sb) << 7) if is_min else ((sa & sb) << 7)
    else:
        r = (A if va < vb else B) if is_min else (A if va > vb else B)
    return r, _cflags(r), 0

def fp8_scalb(A, n, rm):
    s, e, m = unpack(A)
    if is_nan(A): return ((s << 7) | (0xF << 3) | m), (1 << 4) | (1 << 5), 0
    if is_inf(A): return ((s << 7) | (0xF << 3)), (1 << 3), 0
    x = fp8_to_fraction(A)
    if x == 0:    return (s << 7), (1 << 0), 0
    return _round_value(x * (Fraction(2) ** n), rm)

def fp8_roundint(A, rm):
    s, e, m = unpack(A)
    if is_nan(A): return ((s << 7) | (0xF << 3) | m), (1 << 4) | (1 << 5), 0
    if is_inf(A): return ((s << 7) | (0xF << 3)), (1 << 3), 0
    x = fp8_to_fraction(A)
    if x == 0:    return (s << 7), (1 << 0), 0
    lo = Fraction(_math.floor(x)); hi = Fraction(_math.ceil(x))
    if lo == hi:              n = lo
    elif rm == RM_ZERO:       n = lo if x > 0 else hi
    elif rm == RM_UP:         n = hi
    elif rm == RM_DOWN:       n = lo
    elif rm == RM_NEAREST:
        dl, dh = x - lo, hi - x
        n = lo if dl < dh else (hi if dh < dl else (lo if lo % 2 == 0 else hi))
    else:                     n = lo if lo % 2 != 0 else (hi if hi % 2 != 0 else lo)
    if n == 0: return (s << 7), (1 << 0), 0
    r, _, _ = _round_value(Fraction(n), rm)
    return r, _cflags(r), 0                        # roundToIntegral: sem NX


# ----------------------------------------------------------------------
# CONVERSOES INTEIRO <-> FP8   (semantica RISC-V FCVT)
#
# Regra: ARREDONDA primeiro segundo o rm, DEPOIS checa a faixa do inteiro.
# Fora da faixa (ou NaN/Inf) satura no extremo e levanta INVALID.
#
# A IEEE-754 (7.2) manda sinalizar invalid e deixa o resultado "nao
# especificado" nesse caso — ou seja, ela NAO escolhe por voce, mas o
# hardware precisa emitir algum padrao de bits. Escolher o valor do RISC-V
# custa ~20 celulas, deixa o acoplamento com o cv32e40x direto (sem correcao
# em software) e mantem o modelo de referencia TOTAL: toda entrada tem uma
# saida definida, o que permite assinatura exaustiva sem casos "don't care".
#
# Entrada sempre no operando A (as quatro conversoes sao unarias).
# Conversoes PARA inteiro devolvem o inteiro no byte de resultado (complemento
# de dois no caso com sinal) e flags = 0 — mesma convencao de CLASSIFY e
# COMPARE, que tambem devolvem valores que nao sao FP8.
# ----------------------------------------------------------------------
def _round_frac_to_int(x, rm):
    """Arredonda uma Fraction para INTEIRO segundo o modo IEEE. Espelha as
    escolhas de fp8_roundint, mas devolve int em vez de um codigo FP8."""
    lo = _math.floor(x); hi = _math.ceil(x)
    if lo == hi:        return int(lo)
    if rm == RM_ZERO:   return int(lo if x > 0 else hi)
    if rm == RM_UP:     return int(hi)
    if rm == RM_DOWN:   return int(lo)
    if rm == RM_NEAREST:
        dl, dh = x - lo, hi - x
        if dl < dh: return int(lo)
        if dh < dl: return int(hi)
        return int(lo if lo % 2 == 0 else hi)        # empate -> par
    # RM_ODD: escolhe o vizinho impar
    return int(lo if lo % 2 != 0 else (hi if hi % 2 != 0 else lo))


def _cvt_to_int(A, rm, lo_lim, hi_lim, nan_val):
    """Nucleo comum de F2I/F2U: arredonda, depois satura."""
    if is_nan(A):
        return nan_val, 0, _b(E_INVALID)
    if is_inf(A):
        s, _, _ = unpack(A)
        return (lo_lim if s else hi_lim), 0, _b(E_INVALID)
    x = fp8_to_fraction(A)
    n = _round_frac_to_int(x, rm)
    if n < lo_lim: return lo_lim, 0, _b(E_INVALID)
    if n > hi_lim: return hi_lim, 0, _b(E_INVALID)
    # saturacao levanta INVALID e NAO INEXACT (regra do RISC-V)
    return n, 0, (_b(E_INEXACT) if Fraction(n) != x else 0)


def fp8_cvt_f2i(A, rm):
    """fp8 -> int8 com sinal, saturando em [-128, 127]. NaN -> +127."""
    n, fl, ex = _cvt_to_int(A, rm, INT8_MIN, INT8_MAX, INT8_MAX)
    return n & 0xFF, fl, ex                          # complemento de dois


def fp8_cvt_f2u(A, rm):
    """fp8 -> uint8, saturando em [0, 255]. NaN -> 255, negativo -> 0."""
    n, fl, ex = _cvt_to_int(A, rm, UINT8_MIN, UINT8_MAX, UINT8_MAX)
    return n & 0xFF, fl, ex


def fp8_cvt_i2f(A, rm):
    """int8 com sinal -> fp8. Nao ha overflow: |int8| <= 128 < 240 (maior
    finito do E4M3). So pode ser inexato (127 nao e' representavel)."""
    n = A - 256 if A >= 128 else A
    if n == 0:
        return 0x00, _b(F_ZERO), 0                   # inteiro 0 -> +0 sempre
    return _round_value(Fraction(n), rm)


def fp8_cvt_u2f(A, rm):
    """uint8 -> fp8. ESTA conversao pode estourar: 255 > 240, o maior finito.
    O overflow segue a regra por modo do _round_value (Inf ou maior finito)."""
    if A == 0:
        return 0x00, _b(F_ZERO), 0
    return _round_value(Fraction(A), rm)


def fp8_math(A, B, opcode, rm):
    """Mathematical model: (result, flags, exceptions) for A op B in FP8."""
    if opcode == OP_SQRT:
        r, fl, ex = fp8_sqrt(A, rm)
        return r & 0xFF, fl, ex
    if opcode == OP_ABS:      r, fl, ex = fp8_abs(A);            return r & 0xFF, fl, ex
    if opcode == OP_NEG:      r, fl, ex = fp8_neg(A);            return r & 0xFF, fl, ex
    if opcode == OP_COPYSIGN: r, fl, ex = fp8_copysign(A, B);    return r & 0xFF, fl, ex
    if opcode == OP_CLASSIFY: r, fl, ex = fp8_classify(A);       return r & 0xFF, fl, ex
    if opcode == OP_COMPARE:  r, fl, ex = fp8_compare(A, B);     return r & 0xFF, fl, ex
    if opcode == OP_MIN:      r, fl, ex = _minmax(A, B, True);   return r & 0xFF, fl, ex
    if opcode == OP_MAX:      r, fl, ex = _minmax(A, B, False);  return r & 0xFF, fl, ex
    if opcode == OP_SCALB:
        n = B - 256 if B >= 128 else B
        r, fl, ex = fp8_scalb(A, n, rm);                         return r & 0xFF, fl, ex
    if opcode == OP_ROUNDINT: r, fl, ex = fp8_roundint(A, rm);   return r & 0xFF, fl, ex
    if opcode == OP_CVT_F2I:  r, fl, ex = fp8_cvt_f2i(A, rm);    return r & 0xFF, fl, ex
    if opcode == OP_CVT_F2U:  r, fl, ex = fp8_cvt_f2u(A, rm);    return r & 0xFF, fl, ex
    if opcode == OP_CVT_I2F:  r, fl, ex = fp8_cvt_i2f(A, rm);    return r & 0xFF, fl, ex
    if opcode == OP_CVT_U2F:  r, fl, ex = fp8_cvt_u2f(A, rm);    return r & 0xFF, fl, ex
    sp = _special(A, B, opcode, rm)
    if sp is not None:
        res, fl, ex = sp
        return res & 0xFF, fl, ex

    # finite path: both operands are finite and non-zero
    fA = fp8_to_fraction(A)
    fB = fp8_to_fraction(B)
    if opcode == OP_ADD:
        v = fA + fB
    elif opcode == OP_SUB:
        v = fA - fB
    elif opcode == OP_MULT:
        v = fA * fB
    else:                               # OP_DIV (fB != 0 guaranteed)
        v = fA / fB

    res, fl, ex = _round_value(v, rm)
    return res & 0xFF, fl, ex


if __name__ == "__main__":
    cases = [(0x08, 0x18, OP_MULT), (0x01, 0x70, OP_MULT),
             (0x38, 0x38, OP_ADD), (0x79, 0x38, OP_ADD),   # NaN
             (0x38, 0x00, OP_DIV),                          # 1/0
             (0x77, 0x77, OP_ADD)]                          # overflow
    for A, B, o in cases:
        res, fl, ex = fp8_math(A, B, o, RM_NEAREST)
        print(f"  0x{A:02X} op{o} 0x{B:02X} -> res=0x{res:02X} "
              f"flags={fl:07b} exc={ex:05b}")
