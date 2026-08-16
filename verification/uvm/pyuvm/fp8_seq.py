# ======================================================================
# fp8_seq.py — UVM sequences (stimulus generators).
#
# Sequences describe WHAT to send, decoupled from HOW it reaches the pins
# (that is the driver + BFM). Each item is randomized in Python (pyuvm has no
# SV constraint solver) and handed to the sequencer via start_item/finish_item.
# ======================================================================
from pyuvm import uvm_sequence

from fp8_item import Fp8Cmd

# Default opcode/rounding pools. DIV/SQRT exercise the variable-latency path.
ALL_OPS = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17]
ARITH_OPS = [0, 1, 2, 3]           # ADD SUB MUL DIV
CVT_OPS = [14, 15, 16, 17]         # F2I F2U I2F U2F (unarias em A)
ALL_RMS = [0, 1, 2, 3, 4]          # RNE RTZ RUP RDN RODD


class Fp8RandomSeq(uvm_sequence):
    """Constrained-random stream of operations."""

    def __init__(self, name="Fp8RandomSeq", n=300, ops=None, rms=None):
        super().__init__(name)
        self.n = n
        self.ops = ops if ops is not None else ALL_OPS
        self.rms = rms if rms is not None else ALL_RMS

    async def body(self):
        for _ in range(self.n):
            item = Fp8Cmd()
            item.randomize(self.ops, self.rms)
            await self.start_item(item)
            await self.finish_item(item)


class Fp8DirectedSeq(uvm_sequence):
    """A fixed list of corner-case operations (special values)."""

    # (A, B, op, rm) — NaN/Inf/zero/subnormal corners across a few ops.
    CASES = [
        (0x7F, 0x7F, 0, 0),   # NaN + NaN
        (0x78, 0x78, 1, 0),   # +Inf - +Inf -> NaN
        (0x78, 0xF8, 0, 0),   # +Inf + -Inf -> NaN
        (0x00, 0x80, 0, 0),   # +0 + -0
        (0x01, 0x01, 2, 0),   # smallest subnormal * itself -> underflow
        (0x77, 0x77, 2, 0),   # max * max -> overflow
        (0x38, 0x00, 3, 0),   # x / 0 -> Inf, DIVZERO
        (0x40, 0x00, 4, 0),   # sqrt path
        (0x48, 0x00, 8, 0),   # CLASSIFY
        (0x48, 0x50, 9, 0),   # COMPARE
        (0xC8, 0x00, 12, 0),  # NEG
        (0x48, 0x80, 13, 0),  # COPYSIGN
    ]

    def __init__(self, name="Fp8DirectedSeq"):
        super().__init__(name)

    async def body(self):
        for a, b, op, rm in self.CASES:
            item = Fp8Cmd(a=a, b=b, op=op, rm=rm)
            await self.start_item(item)
            await self.finish_item(item)
