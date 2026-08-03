MATHEMATICAL MODEL — FP8 E4M3 VERIFICATION (IEEE-like specification)
====================================================================
This folder's reference is now the MATHEMATICAL SPECIFICATION (exact value
as a Fraction + IEEE exceptions), no longer a bit-accurate mirror of the RTL.
The mathematical model was verified identical to the old RTL golden model
(fp8_golden_c2) across all 1,310,720 cases — 256 x 256 x 4 ops x 5 modes —
returning the same triple (result, flags, exc).

FP8 MODEL FILES (3)
  fp8_common.py        base: FP8 E4M3 codec (unpack, exact value as Fraction).
  fp8_math.py          SPECIFICATION: A op B as an exact value + exceptions,
                       rounded to FP8 in the 5 modes. -> (result, flags, exc).
  gen_vectors_math.py  generates the 7-column vectors.hex for tb_fp8_golden.v.

OTHER
  vectors.hex          committed golden vectors (7 columns). The repo ships a
                       ~30k evenly-sampled subset (enough to exercise the
                       corners while keeping the repo small); running
                       gen_vectors_math.py with no arguments regenerates the
                       full exhaustive 1,310,720-line set.

DEPENDENCIES
  fp8_math         <- fp8_common            (self-contained)
  gen_vectors_math <- fp8_common, fp8_math
                      (fp8_golden_c2 only if --check is used; not in this folder)

MODEL API
  fp8_math(A, B, opcode, rm) -> (result, flags, exc)
    opcode: 0=ADD 1=SUB 2=MULT 3=DIV
    rm    : 0=NEAR 1=ZERO 2=UP 3=DOWN 4=ODD
  Flags  (header_fp8.v): SNAN6 QNAN5 NAN4 INF3 NORMAL2 SUBNORMAL1 ZERO0
  Excs   (header_fp8.v): INVALID4 DIVZERO3 OVERFLOW2 UNDERFLOW1 INEXACT0

EXCEPTIONS HANDLED (at the value level)
  INVALID  : Inf-Inf, 0/0, Inf*0, input NaN (propagates operand, quiet).
  DIVZERO  : finite x/0 -> +-Inf.
  OVERFLOW : above the largest finite -> Inf, depending on the mode
             (NEAREST/UP+/DOWN-); ZERO/ODD and the opposite side of UP/DOWN
             saturate at the largest finite.
  UNDERFLOW: a non-zero value that collapses to zero when rounded.
  INEXACT  : the rounded result differs from the exact value.

GENERATE VECTORS (7 columns: AA BB O R RES FF EE)
  python3 gen_vectors_math.py            # ADD/SUB/MULT/DIV, 5 modes
  python3 gen_vectors_math.py --rne      # RM_NEAREST only
  python3 gen_vectors_math.py --quick    # small sample (smoke test)
  python3 gen_vectors_math.py --no-div   # exclude DIV
  python3 gen_vectors_math.py --out X.hex
  python3 gen_vectors_math.py --check    # compare vs fp8_golden_c2 (if present)

STATUS: ADD/SUB/MULT/DIV = 0% divergence between the mathematical
specification and the RTL golden model across the 5 modes (1,310,720/1,310,720).
