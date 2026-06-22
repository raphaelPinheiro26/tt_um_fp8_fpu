#!/usr/bin/env python3
# ======================================================================
# gen_vectors_math.py — Gera vectors.hex de 7 COLUNAS a partir da
# ESPECIFICAÇÃO MATEMÁTICA (fp8_math), não do espelho do RTL.
#
# Formato idêntico ao gen_vectors_golden.py (consumido por
# tb_fp8_golden.v via $fscanf de 7 campos):
#   AA BB O R RES FF EE
#     AA = operando A (8 bits)
#     BB = operando B (8 bits)
#     O  = opcode  (0=ADD 1=SUB 2=MULT 3=DIV)
#     R  = rounding mode (0=NEAR 1=ZERO 2=UP 3=DOWN 4=ODD)
#     RES= resultado esperado (8 bits)
#     FF = flags esperadas (7 bits úteis)
#     EE = exceptions esperadas (5 bits úteis)
#
# A referência aqui é fp8_math (valor exato em Fraction + exceções IEEE),
# verificada idêntica a fp8_golden_c2 nos 1.310.720 casos. Gerar o .hex
# pela especificação deixa o testbench validando o RTL contra a MATEMÁTICA.
#
# Depende de: fp8_common, fp8_math. (fp8_golden_c2 só se usar --check.)
#
# Uso:
#   python3 gen_vectors_math.py               # ADD/SUB/MULT/DIV, 5 modos
#   python3 gen_vectors_math.py --rne         # só RM_NEAREST
#   python3 gen_vectors_math.py --no-div      # exclui DIV
#   python3 gen_vectors_math.py --quick       # amostra pequena (smoke)
#   python3 gen_vectors_math.py --out foo.hex
#   python3 gen_vectors_math.py --check       # confere math == golden_c2 ao gerar
# ======================================================================
import sys
from fp8_common import OP_ADD, OP_SUB, OP_MULT, OP_DIV
from fp8_math import fp8_math

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
    out = "vectors.hex"
    if "--out" in args:
        out = args[args.index("--out") + 1]

    if check:
        try:
            from fp8_golden_c2 import fp8_golden_c2
        except ImportError:
            print("--check ignorado: fp8_golden_c2 não está presente.")
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

    op_names = ['ADD', 'SUB', 'MULT', 'DIV'][:len(ops)]
    print(f"{n} vetores -> {out}  (7 colunas, ops={op_names}, modos={rms})")
    print("Formato: AA BB O R RES FF EE  (compatível com tb_fp8_golden.v)")
    print("Referência: fp8_math (especificação matemática)")
    if check:
        if mism == 0:
            print(f"--check: OK, fp8_math == fp8_golden_c2 em {n} vetores.")
        else:
            print(f"--check: {mism} DIVERGÊNCIAS vs fp8_golden_c2!")
            sys.exit(1)


if __name__ == "__main__":
    main()
