# ======================================================================
# fp8_ref.py — Reference-model adapter for the UVM scoreboard.
#
# The scoreboard must predict the DUT's output for any (A, B, opcode, rm).
# Instead of re-implementing FP8 math (and risking a buggy oracle), we reuse
# the project's SIGN-OFF reference: Golden_model/fp8_math.py, the exact
# Fraction-based mathematical specification the RTL was audited against
# (verified identical across all 1,310,720 cases). This is the professional
# move — one source of truth for "correct", shared by simulation and UVM.
# ======================================================================
import os
import sys

# Make Golden_model importable regardless of where the sim is launched from.
_HERE = os.path.dirname(os.path.abspath(__file__))
_GOLDEN = os.path.abspath(os.path.join(_HERE, "..", "..", "..", "Golden_model"))
if _GOLDEN not in sys.path:
    sys.path.insert(0, _GOLDEN)

from fp8_math import fp8_math  # noqa: E402

FLAG_MASK = 0x7F   # 7 classification-flag bits (header_fp8.v)
EXC_MASK = 0x1F    # 5 IEEE exception bits


def predict(a, b, opcode, rm):
    """Return the expected (result, flags, exceptions) triple for one op."""
    res, flags, exc = fp8_math(a & 0xFF, b & 0xFF, opcode, rm)
    return res & 0xFF, flags & FLAG_MASK, exc & EXC_MASK


# Opcodes that take two operands (B is meaningful). Unary ops ignore B; the
# random sequence still drives a B byte over the wire (the protocol always
# sends it in non-sticky mode), but the reference ignores it for those ops.
BINARY_OPS = {0, 1, 2, 3, 5, 6, 9, 13}   # ADD SUB MUL DIV MIN MAX COMPARE COPYSIGN

OP_NAMES = {
    0: "ADD", 1: "SUB", 2: "MUL", 3: "DIV", 4: "SQRT", 5: "MIN", 6: "MAX",
    7: "ABS", 8: "CLASSIFY", 9: "COMPARE", 10: "SCALB", 11: "ROUNDINT",
    12: "NEG", 13: "COPYSIGN",
}
RM_NAMES = {0: "RNE", 1: "RTZ", 2: "RUP", 3: "RDN", 4: "RODD"}
