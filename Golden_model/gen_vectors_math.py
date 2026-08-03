#!/usr/bin/env python3
# ======================================================================
# gen_vectors_math.py — Generates the 7-COLUMN vectors.hex from the
# MATHEMATICAL SPECIFICATION (fp8_math), not from the RTL mirror.
#
# Format identical to gen_vectors_golden.py (consumed by tb_fp8_golden.v
# via a 7-field $fscanf):
#   AA BB O R RES FF EE
#     AA = operand A (8 bits)
#     BB = operand B (8 bits)
#     O  = opcode  (0=ADD 1=SUB 2=MULT 3=DIV 12=NEG 13=COPYSIGN)
#     R  = rounding mode (0=NEAR 1=ZERO 2=UP 3=DOWN 4=ODD)
#     RES= expected result (8 bits)
#     FF = expected flags (7 useful bits)
#     EE = expected exceptions (5 useful bits)
#
# The reference here is fp8_math (exact value as a Fraction + IEEE
# exceptions), verified identical to fp8_golden_c2 across all 1,310,720
# cases. Generating the .hex from the specification makes the testbench
# validate the RTL against the MATH.
#
# Depends on: fp8_common, fp8_math. (fp8_golden_c2 only if --check.)
#
# Usage:
#   python3 gen_vectors_math.py               # ADD/SUB/MULT/DIV + NEG/COPYSIGN
#   python3 gen_vectors_math.py --rne         # RM_NEAREST only (arith ops)
#   python3 gen_vectors_math.py --no-div      # exclude DIV
#   python3 gen_vectors_math.py --no-sign     # exclude NEG/COPYSIGN
#   python3 gen_vectors_math.py --quick       # small sample (smoke)
#   python3 gen_vectors_math.py --out foo.hex
#   python3 gen_vectors_math.py --check       # check math == golden_c2 while generating
# ======================================================================
import sys
from fp8_common import OP_ADD, OP_SUB, OP_MULT, OP_DIV, OP_NEG, OP_COPYSIGN
from fp8_math import fp8_math

# COPYSIGN so' depende do bit de sinal de B; estes dois doadores cobrem
# sinal 0 e sinal 1 (suficiente para exercitar a operacao exaustivamente em A).
COPYSIGN_B = [0x00, 0x80]

ALL_RM = [0, 1, 2, 3, 4]
QUICK_VALS = [0x00, 0x01, 0x07, 0x08, 0x18, 0x20, 0x38, 0x40,
              0x3C, 0x70, 0x77, 0x78, 0x79, 0x80, 0xB8, 0xF8]


def main():
    args = sys.argv[1:]
    rms = [0] if "--rne" in args else ALL_RM
    ops = [OP_ADD, OP_SUB, OP_MULT]
    if "--no-div" not in args:
        ops.append(OP_DIV)
    quick = "--quick" in args
    check = "--check" in args
    # ops de sinal (NEG/COPYSIGN): incluidas por padrao; --no-sign as exclui.
    do_sign = "--no-sign" not in args
    out = "vectors.hex"
    if "--out" in args:
        out = args[args.index("--out") + 1]

    if check:
        try:
            from fp8_golden_c2 import fp8_golden_c2
        except ImportError:
            print("--check ignored: fp8_golden_c2 is not present.")
            check = False

    vals = QUICK_VALS if quick else list(range(256))

    n = 0
    mism = 0
    with open(out, "w") as f:
        for op in ops:
            for rm in rms:
                for a in vals:
                    for b in vals:
                        res, fl, ex = fp8_math(a, b, op, rm)
                        if check and (res, fl, ex) != fp8_golden_c2(a, b, op, rm):
                            mism += 1
                            if mism <= 10:
                                print(f"  MISMATCH A=0x{a:02x} B=0x{b:02x} "
                                      f"op={op} rm={rm}")
                        f.write(f"{a:02x} {b:02x} {op:01x} {rm:01x} "
                                f"{res:02x} {fl:02x} {ex:02x}\n")
                        n += 1

        # --- ops de sinal: sem excecoes e independentes do rm ---------------
        # NEG e' unaria (B ignorado); COPYSIGN usa apenas o sinal de B. Por
        # isso geramos com rm=0 e sem varrer rm/b redundantes.
        if do_sign:
            for a in vals:
                res, fl, ex = fp8_math(a, 0x00, OP_NEG, 0)
                f.write(f"{a:02x} 00 {OP_NEG:01x} 0 {res:02x} {fl:02x} {ex:02x}\n")
                n += 1
            for b in COPYSIGN_B:
                for a in vals:
                    res, fl, ex = fp8_math(a, b, OP_COPYSIGN, 0)
                    f.write(f"{a:02x} {b:02x} {OP_COPYSIGN:01x} 0 "
                            f"{res:02x} {fl:02x} {ex:02x}\n")
                    n += 1

    op_names = ['ADD', 'SUB', 'MULT', 'DIV'][:len(ops)]
    if do_sign:
        op_names += ['NEG', 'COPYSIGN']
    print(f"{n} vectors -> {out}  (7 columns, ops={op_names}, modes={rms})")
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
