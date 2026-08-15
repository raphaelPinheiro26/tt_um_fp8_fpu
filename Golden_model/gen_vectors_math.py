#!/usr/bin/env python3
# ======================================================================
# gen_vectors_math.py — Generates the 7-COLUMN vectors.hex from the
# MATHEMATICAL SPECIFICATION (fp8_math), not from the RTL mirror.
#
# Format identical to gen_vectors_golden.py (consumed by tb_fp8_golden.v
# via a 7-field $fscanf):
#   AA BB O R RES FF EE
#     AA = operand A (8 bits)
#     BB = operand B (8 bits)  — also the int8 shift 'n' for SCALB
#     O  = opcode  (see OP_SPEC below)
#     R  = rounding mode (0=NEAR 1=ZERO 2=UP 3=DOWN 4=ODD)
#     RES= expected result (8 bits)
#     FF = expected flags (7 useful bits)
#     EE = expected exceptions (5 useful bits)
#
# The reference here is fp8_math (exact value as a Fraction + IEEE
# exceptions), verified identical to fp8_golden_c2 across all 1,310,720
# arithmetic cases. Generating the .hex from the specification makes the
# testbench validate the RTL against the MATH.
#
# Depends on: fp8_common, fp8_math. (fp8_golden_c2 only if --check.)
#
# ----------------------------------------------------------------------
# COVERAGE NOTE
# ----------------------------------------------------------------------
# The default invocation reproduces the historical sign-off set
# (ADD/SUB/MULT/DIV + NEG/COPYSIGN) byte for byte, so the committed
# vectors.hex and the CI keep their meaning.
#
# The RTL also implements SQRT, MIN, MAX, ABS, CLASSIFY, COMPARE, SCALB
# and ROUNDINT, which were historically NOT part of the vector sign-off.
# (A real SCALB bug was found by the pyuvm testbench precisely because of
# that gap — see the comment in src/fp8_elastic_pipeline.v.) Use --new to
# emit exactly those eight, or --all for the full instruction set.
#
# Usage:
# The default output file follows the selection, so that --new can never
# clobber the arithmetic sign-off set:
#   (default) -> vectors.hex        --new  -> vectors_newops.hex
#   --all     -> vectors_all.hex    --ops  -> vectors_custom.hex
#   --cvt     -> vectors_cvt.hex
# --out always wins.
#
#   python3 gen_vectors_math.py               # ADD/SUB/MULT/DIV + NEG/COPYSIGN
#   python3 gen_vectors_math.py --all         # every opcode the RTL implements
#   python3 gen_vectors_math.py --new         # only the 8 never-signed-off ops
#   python3 gen_vectors_math.py --cvt         # only the 4 integer conversions
#   python3 gen_vectors_math.py --ops sqrt,min,max
#   python3 gen_vectors_math.py --rne         # RM_NEAREST only (rm-dependent ops)
#   python3 gen_vectors_math.py --no-div      # exclude DIV
#   python3 gen_vectors_math.py --no-sign     # exclude NEG/COPYSIGN
#   python3 gen_vectors_math.py --quick       # small sample (smoke)
#   python3 gen_vectors_math.py --out foo.hex
#   python3 gen_vectors_math.py --check       # check math == golden_c2 while generating
# ======================================================================
import sys
from fp8_common import (OP_ADD, OP_SUB, OP_MULT, OP_DIV, OP_SQRT, OP_MIN,
                        OP_MAX, OP_ABS, OP_CLASSIFY, OP_COMPARE, OP_SCALB,
                        OP_ROUNDINT, OP_NEG, OP_COPYSIGN,
                        OP_CVT_F2I, OP_CVT_F2U, OP_CVT_I2F, OP_CVT_U2F,
                        OP_NAMES)
from fp8_math import fp8_math

# COPYSIGN so' depende do bit de sinal de B; estes dois doadores cobrem
# sinal 0 e sinal 1 (suficiente para exercitar a operacao exaustivamente em A).
COPYSIGN_B = [0x00, 0x80]

ALL_RM = [0, 1, 2, 3, 4]
QUICK_VALS = [0x00, 0x01, 0x07, 0x08, 0x18, 0x20, 0x38, 0x40,
              0x3C, 0x70, 0x77, 0x78, 0x79, 0x80, 0xB8, 0xF8]

# ----------------------------------------------------------------------
# Per-opcode generation spec:  opcode -> (arity, rm_dependent)
#
#   arity 1  -> unary; B is driven to 0x00 and ignored by the RTL
#   arity 2  -> binary; full A x B sweep
#   rm_dep   -> whether the result depends on the rounding mode. Ops that
#               do not are emitted once with rm=0 instead of five times,
#               which keeps the file small without losing any coverage.
#
# COPYSIGN is arity 2 but only the SIGN of B matters, so it gets a
# dedicated donor list (COPYSIGN_B) rather than a 256x256 sweep.
# SCALB is arity 2 but B is an int8 exponent, not an FP8 code; sweeping
# all 256 B values covers the RTL's +31/-32 exponent saturation too.
# ----------------------------------------------------------------------
OP_SPEC = {
    OP_ADD:      (2, True),
    OP_SUB:      (2, True),
    OP_MULT:     (2, True),
    OP_DIV:      (2, True),
    OP_SQRT:     (1, True),
    OP_MIN:      (2, False),
    OP_MAX:      (2, False),
    OP_ABS:      (1, False),
    OP_CLASSIFY: (1, False),
    OP_COMPARE:  (2, False),
    OP_SCALB:    (2, True),
    OP_ROUNDINT: (1, True),
    OP_NEG:      (1, False),
    OP_COPYSIGN: (2, False),
    # conversoes: unarias em A, e todas dependem do modo de arredondamento
    # (F2I/F2U arredondam antes de checar a faixa; I2F/U2F arredondam o
    #  inteiro para a grade do E4M3).
    OP_CVT_F2I:  (1, True),
    OP_CVT_F2U:  (1, True),
    OP_CVT_I2F:  (1, True),
    OP_CVT_U2F:  (1, True),
}

# NEG/COPYSIGN stay in their historical position so the default selection
# reproduces vectors.hex byte for byte; CVT is appended after them.
OP_ORDER = [OP_ADD, OP_SUB, OP_MULT, OP_DIV, OP_SQRT, OP_MIN, OP_MAX,
            OP_ABS, OP_CLASSIFY, OP_COMPARE, OP_SCALB, OP_ROUNDINT,
            OP_NEG, OP_COPYSIGN,
            OP_CVT_F2I, OP_CVT_F2U, OP_CVT_I2F, OP_CVT_U2F]

DEFAULT_OPS = {OP_ADD, OP_SUB, OP_MULT, OP_DIV, OP_NEG, OP_COPYSIGN}
NEW_OPS = {OP_SQRT, OP_MIN, OP_MAX, OP_ABS, OP_CLASSIFY, OP_COMPARE,
           OP_SCALB, OP_ROUNDINT}
CVT_OPS = {OP_CVT_F2I, OP_CVT_F2U, OP_CVT_I2F, OP_CVT_U2F}

NAME_TO_OP = {v.lower(): k for k, v in OP_NAMES.items()}


def iter_cases(op, vals, rms):
    """Yield (a, b, rm) for one opcode, in canonical order."""
    arity, rm_dep = OP_SPEC[op]
    use_rms = rms if rm_dep else [0]

    if op == OP_COPYSIGN:
        for b in COPYSIGN_B:
            for a in vals:
                yield a, b, 0
        return

    for rm in use_rms:
        if arity == 1:
            for a in vals:
                yield a, 0x00, rm
        else:
            for a in vals:
                for b in vals:
                    yield a, b, rm


def parse_ops(args):
    """Resolve the requested opcode set from the CLI flags."""
    if "--all" in args:
        sel = set(OP_ORDER)
    elif "--new" in args:
        sel = set(NEW_OPS)
    elif "--cvt" in args:
        sel = set(CVT_OPS)
    elif "--ops" in args:
        names = args[args.index("--ops") + 1].split(",")
        sel = set()
        for nm in names:
            nm = nm.strip().lower()
            if nm not in NAME_TO_OP:
                sys.exit(f"unknown op '{nm}'. valid: "
                         f"{','.join(sorted(NAME_TO_OP))}")
            sel.add(NAME_TO_OP[nm])
        return sel                      # explicit list wins over --no-*
    else:
        sel = set(DEFAULT_OPS)

    if "--no-div" in args:
        sel.discard(OP_DIV)
    if "--no-sign" in args:
        sel.discard(OP_NEG)
        sel.discard(OP_COPYSIGN)
    return sel


def main():
    args = sys.argv[1:]
    rms = [0] if "--rne" in args else ALL_RM
    quick = "--quick" in args
    check = "--check" in args
    ops = parse_ops(args)
    # Default output depends on the selection, so that `--new` cannot silently
    # clobber the arithmetic sign-off set. Only the default (arithmetic + sign)
    # selection writes vectors.hex.
    if "--out" in args:
        out = args[args.index("--out") + 1]
    elif "--new" in args:
        out = "vectors_newops.hex"
    elif "--cvt" in args:
        out = "vectors_cvt.hex"
    elif "--all" in args:
        out = "vectors_all.hex"
    elif "--ops" in args:
        out = "vectors_custom.hex"
    else:
        out = "vectors.hex"

    if check:
        try:
            from fp8_golden_c2 import fp8_golden_c2
        except ImportError:
            print("--check ignored: fp8_golden_c2 is not present.")
            check = False

    vals = QUICK_VALS if quick else list(range(256))

    n = 0
    mism = 0
    per_op = {}
    with open(out, "w") as f:
        for op in OP_ORDER:
            if op not in ops:
                continue
            cnt = 0
            for a, b, rm in iter_cases(op, vals, rms):
                res, fl, ex = fp8_math(a, b, op, rm)
                # fp8_golden_c2 only models the four arithmetic opcodes.
                if check and op in (OP_ADD, OP_SUB, OP_MULT, OP_DIV):
                    if (res, fl, ex) != fp8_golden_c2(a, b, op, rm):
                        mism += 1
                        if mism <= 10:
                            print(f"  MISMATCH A=0x{a:02x} B=0x{b:02x} "
                                  f"op={op} rm={rm}")
                f.write(f"{a:02x} {b:02x} {op:01x} {rm:01x} "
                        f"{res:02x} {fl:02x} {ex:02x}\n")
                cnt += 1
                n += 1
            per_op[op] = cnt

    print(f"{n} vectors -> {out}  (7 columns, modes={rms})")
    for op in OP_ORDER:
        if op in per_op:
            arity, rm_dep = OP_SPEC[op]
            print(f"  {OP_NAMES[op]:<9} {per_op[op]:>8}   "
                  f"arity={arity} rm={'yes' if rm_dep else 'n/a'}")
    print("Format: AA BB O R RES FF EE  (compatible with tb_fp8_golden.v)")
    print("Reference: fp8_math (mathematical specification)")
    if check:
        if mism == 0:
            print(f"--check: OK, fp8_math == fp8_golden_c2 over {n} vectors.")
        else:
            print(f"--check: {mism} DIVERGENCES vs fp8_golden_c2!")
            sys.exit(1)


if __name__ == "__main__":
    main()
