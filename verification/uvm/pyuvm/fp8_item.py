# ======================================================================
# fp8_item.py — UVM sequence items (transactions).
#
# Two transaction types flow through the environment:
#   Fp8Cmd    — one issued operation (A, B, opcode, rm), produced by sequences
#               and reconstructed by the command monitor from the DUT pins.
#   Fp8Result — one completed result (result, flags, exceptions), reconstructed
#               by the result monitor from the DUT output stream.
# ======================================================================
import random

from pyuvm import uvm_sequence_item

from fp8_ref import OP_NAMES, RM_NAMES


class Fp8Cmd(uvm_sequence_item):
    """A single FP8 operation request."""

    def __init__(self, name="Fp8Cmd", a=0, b=0, op=0, rm=0):
        super().__init__(name)
        self.a = a
        self.b = b
        self.op = op
        self.rm = rm

    def randomize(self, ops, rms):
        """pyuvm has no SV constraint solver — randomize in plain Python."""
        self.a = random.randint(0, 0xFF)
        self.b = random.randint(0, 0xFF)
        self.op = random.choice(ops)
        self.rm = random.choice(rms)
        return self

    def __eq__(self, other):
        return (self.a, self.b, self.op, self.rm) == \
               (other.a, other.b, other.op, other.rm)

    def __str__(self):
        op_name = OP_NAMES.get(self.op, str(self.op))
        rm_name = RM_NAMES.get(self.rm, str(self.rm))
        return (f"{op_name:8s} A=0x{self.a:02X} B=0x{self.b:02X} rm={rm_name}")


class Fp8Result(uvm_sequence_item):
    """A single completed FP8 result (result + flags + exceptions bytes)."""

    def __init__(self, name="Fp8Result", result=0, flags=0, exc=0):
        super().__init__(name)
        self.result = result
        self.flags = flags
        self.exc = exc

    def __eq__(self, other):
        return (self.result, self.flags, self.exc) == \
               (other.result, other.flags, other.exc)

    def __str__(self):
        return (f"result=0x{self.result:02X} "
                f"flags=0x{self.flags:02X} exc=0x{self.exc:02X}")
