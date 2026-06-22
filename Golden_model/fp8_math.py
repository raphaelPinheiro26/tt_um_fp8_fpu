#!/usr/bin/env python3
# ======================================================================
# fp8_math.py — Modelo PURAMENTE MATEMÁTICO da FPU FP8 E4M3.
#
# Diferente de fp8_golden_c2 / fp8_model_c2 (que espelham o datapath do
# RTL: prenorm, régua larga de 16 bits, sticky, G=20, QDIV=10), este
# módulo trabalha SÓ COM VALOR:
#
#   1) casos especiais (NaN / Inf / Zero) resolvidos no nível de valor;
#   2) o resultado finito é o valor EXATO  fA op fB  como Fraction
#      (sem nenhum erro de ponto flutuante intermediário);
#   3) esse valor exato é arredondado para FP8 (arredondador IEEE-like
#      embutido) e as flags/exceções IEEE são deduzidas do resultado.
#
# É a ESPECIFICAÇÃO matemática contra a qual o RTL é auditado. Foi
# verificado idêntico a fp8_golden_c2 nos 1.310.720 casos
# (256 x 256 x 4 ops x 5 modos), retornando a mesma tripla.
#
# Depende SOMENTE de fp8_common (auto-contido).
#
# Posições de flag/exc seguem header_fp8.v:
#   FLAG: SNAN6 QNAN5 NAN4 INF3 NORMAL2 SUBNORMAL1 ZERO0
#   EXC : INVALID4 DIVZERO3 OVERFLOW2 UNDERFLOW1 INEXACT0
#
# API:
#   fp8_math(A, B, opcode, rm) -> (result, flags, exceptions)
# ======================================================================
from fractions import Fraction
from fp8_common import (unpack, is_special, is_nan, is_inf, fp8_to_fraction,
                        OP_ADD, OP_SUB, OP_MULT, OP_DIV,
                        RM_NEAREST, RM_ZERO, RM_UP, RM_DOWN, RM_ODD,
                        CANONICAL_NAN, MAXFIN_VAL, ULP_TOP)

# --- bits de flag (classificação do resultado) ---
F_SNAN, F_QNAN, F_NAN, F_INF, F_NORMAL, F_SUBNORMAL, F_ZERO = 6, 5, 4, 3, 2, 1, 0
# --- bits de exceção IEEE ---
E_INVALID, E_DIVZERO, E_OVERFLOW, E_UNDERFLOW, E_INEXACT = 4, 3, 2, 1, 0


def _b(i):
    return 1 << i


# ----------------------------------------------------------------------
# ARREDONDADOR IEEE-LIKE (embutido) — arredonda um Fraction exato para um
# código FP8 em qualquer um dos 5 modos. Trabalha sobre a grade de finitos
# representáveis; overflow vai a Inf conforme o modo.
# ----------------------------------------------------------------------
_POS = sorted(                                  # (valor, código) dos finitos >= 0
    (fp8_to_fraction(c), c)
    for c in range(0x80)
    if not is_special(c) and fp8_to_fraction(c) is not None
       and fp8_to_fraction(c) >= 0
)
_HALFWAY = MAXFIN_VAL + ULP_TOP / 2             # ponto médio até o "próximo" virtual


def _ideal(value, rm):
    """Arredonda um Fraction exato para FP8 no modo rm. value pode ser 0."""
    if value == 0:
        return 0x00
    sign = 0 if value > 0 else 1
    v = abs(value)

    # overflow (acima do maior finito)
    if v > MAXFIN_VAL:
        mx = (sign << 7) | 0x77
        inf = (sign << 7) | (0xF << 3)
        if rm == RM_ZERO or rm == RM_ODD:
            return mx
        if rm == RM_UP:
            return inf if sign == 0 else mx
        if rm == RM_DOWN:
            return inf if sign == 1 else mx
        return inf if v >= _HALFWAY else mx     # NEAREST: tie e acima -> Inf

    # vizinhos lo <= v <= hi na grade representável
    lo = hi = None
    for val, code in _POS:
        if val <= v:
            lo = (val, code)
        if val >= v and hi is None:
            hi = (val, code)

    if lo and lo[0] == v:                       # exatamente representável
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
        else:                                   # empate -> par
            pick = lc if (lc & 1) == 0 else hc
    else:                                       # RM_ODD: inexato escolhe LSB=1
        if (lc & 1) == 1:
            pick = lc
        elif (hc & 1) == 1:
            pick = hc
        else:
            pick = lc
    return (sign << 7) | pick


# ----------------------------------------------------------------------
# CASOS ESPECIAIS — resolvidos por VALOR (NaN/Inf/Zero), não por datapath.
# Retorna (result, flags, exc) ou None se for caminho finito normal.
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
    # sinal efetivo de B: subtração = adição com B negado
    sBx = (1 - sB) if op == OP_SUB else sB

    INVALID = (CANONICAL_NAN, _b(F_NAN) | _b(F_QNAN), _b(E_INVALID))

    # --- NaN de entrada: propaga o operando (quiet), sinaliza inválido ---
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
        return (sA << 7) | (0xF << 3), _b(F_INF), 0    # Inf + Inf (mesmo sinal)

    # --- Inf op finito  /  finito op Inf ---
    if a_inf or b_inf:
        if op == OP_MULT:
            if (a_inf and b_zero) or (b_inf and a_zero):
                return INVALID                         # Inf * 0
            return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), 0
        if op == OP_DIV:
            if a_inf:                                  # Inf / finito = Inf
                return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), 0
            return ((sA ^ sB) << 7), _b(F_ZERO), 0     # finito / Inf = 0
        res = (sA << 7) | (0xF << 3) if a_inf else (sBx << 7) | (0xF << 3)
        return res, _b(F_INF), 0                       # Inf +/- finito = +/-Inf

    # --- 0 op 0 ---
    if a_zero and b_zero:
        if op == OP_DIV:                               # 0/0
            return INVALID
        if op == OP_MULT:
            return ((sA ^ sB) << 7), _b(F_ZERO), 0
        if op == OP_SUB:
            rsz = 1 if rm == RM_DOWN else 0            # 0-0 = +0 (-0 em DOWN)
        else:
            rsz = sA & sBx                             # 0+0 = -0 só se ambos -0
        return (rsz << 7), _b(F_ZERO), 0

    # --- 0 op finito ---
    if a_zero:
        if op in (OP_MULT, OP_DIV):
            return ((sA ^ sB) << 7), _b(F_ZERO), 0     # 0*x=+-0 ; 0/x=+-0
        res = (sBx << 7) | (eB << 3) | mB              # 0 +/- B = +/-B
        return res, (_b(F_SUBNORMAL) if b_sub else _b(F_NORMAL)), 0

    # --- finito op 0 ---
    if b_zero:
        if op == OP_MULT:
            return ((sA ^ sB) << 7), _b(F_ZERO), 0
        if op == OP_DIV:                               # x/0 = +-Inf
            return ((sA ^ sB) << 7) | (0xF << 3), _b(F_INF), _b(E_DIVZERO)
        res = (sA << 7) | (eA << 3) | mA               # A +/- 0 = A
        return res, (_b(F_SUBNORMAL) if a_sub else _b(F_NORMAL)), 0

    return None                                        # caminho finito normal


# ----------------------------------------------------------------------
# ARREDONDAMENTO POR VALOR — recebe o valor exato (Fraction) e o modo,
# devolve (result, flags, exc). Flags vêm da classificação do byte
# resultante; exceções (INEXACT/OVERFLOW/UNDERFLOW) vêm da comparação
# entre valor exato e valor arredondado.
# ----------------------------------------------------------------------
def _round_value(v, rm):
    # cancelamento exato (ex.: x - x): +0, ou -0 no modo DOWN
    if v == 0:
        return (0x80 if rm == RM_DOWN else 0x00), _b(F_ZERO), 0

    byte = _ideal(v, rm)                # arredondador IEEE-like (embutido)
    s, e, m = unpack(byte)

    # overflow para Infinito (acima do maior finito, segundo o modo)
    if e == 0xF and m == 0:
        return byte, _b(F_INF), _b(E_OVERFLOW) | _b(E_INEXACT)

    rv = fp8_to_fraction(byte)          # valor exato do código arredondado
    inexact = (rv != v)
    exc = _b(E_INEXACT) if inexact else 0

    if e == 0 and m == 0:               # resultado virou zero
        flags = _b(F_ZERO)
        if inexact:                     # valor != 0 que colapsou em 0 => underflow
            exc |= _b(E_UNDERFLOW)
    elif e == 0:                        # subnormal
        flags = _b(F_SUBNORMAL)
    else:                               # normal (inclui saturação no maior finito)
        flags = _b(F_NORMAL)
    return byte, flags, exc


# ----------------------------------------------------------------------
def fp8_math(A, B, opcode, rm):
    """Modelo matemático: (result, flags, exceptions) para A op B em FP8."""
    sp = _special(A, B, opcode, rm)
    if sp is not None:
        res, fl, ex = sp
        return res & 0xFF, fl, ex

    # caminho finito: ambos os operandos são finitos e diferentes de zero
    fA = fp8_to_fraction(A)
    fB = fp8_to_fraction(B)
    if opcode == OP_ADD:
        v = fA + fB
    elif opcode == OP_SUB:
        v = fA - fB
    elif opcode == OP_MULT:
        v = fA * fB
    else:                               # OP_DIV (fB != 0 garantido)
        v = fA / fB

    res, fl, ex = _round_value(v, rm)
    return res & 0xFF, fl, ex


if __name__ == "__main__":
    casos = [(0x08, 0x18, OP_MULT), (0x01, 0x70, OP_MULT),
             (0x38, 0x38, OP_ADD), (0x79, 0x38, OP_ADD),   # NaN
             (0x38, 0x00, OP_DIV),                          # 1/0
             (0x77, 0x77, OP_ADD)]                          # overflow
    for A, B, o in casos:
        res, fl, ex = fp8_math(A, B, o, RM_NEAREST)
        print(f"  0x{A:02X} op{o} 0x{B:02X} -> res=0x{res:02X} "
              f"flags={fl:07b} exc={ex:05b}")
