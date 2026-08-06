# ======================================================================
# fp8_test.py — UVM tests + the cocotb entry point.
#
# Each uvm_test builds the environment and runs sequences on the agent's
# sequencer. The cocotb @test coroutine starts the clock and hands control to
# the UVM run flow (uvm_root().run_test).
#
# Run:  make            (default: Fp8SmokeTest)
#       make TEST=Fp8ArithTest
#       make TEST=Fp8FullRandomTest
# ======================================================================
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from pyuvm import uvm_test, uvm_root

from fp8_components import Fp8Env
from fp8_seq import (ALL_OPS, ALL_RMS, ARITH_OPS, Fp8DirectedSeq, Fp8RandomSeq)


class Fp8BaseTest(uvm_test):
    """Common flow: build env, run directed + random, wait for drain, check."""

    # Overridable knobs.
    N_RANDOM = 300
    OPS = ALL_OPS
    RMS = ALL_RMS
    RUN_DIRECTED = True

    def build_phase(self):
        self.env = Fp8Env("env", self)

    async def run_phase(self):
        self.raise_objection()
        seqr = self.env.agent.seqr

        total = 0
        if self.RUN_DIRECTED:
            directed = Fp8DirectedSeq()
            await directed.start(seqr)
            total += len(Fp8DirectedSeq.CASES)

        rand = Fp8RandomSeq(n=self.N_RANDOM, ops=self.OPS, rms=self.RMS)
        await rand.start(seqr)
        total += self.N_RANDOM

        # Wait for the pipeline + output serialiser to drain every result.
        # Generous bound: the iterative divider is the slowest op.
        sb = self.env.sb
        for _ in range(total * 60 + 500):
            if sb.count >= total:
                break
            await ClockCycles(cocotb.top.clk, 1)

        if sb.count < total:
            self.logger.error(
                f"TIMEOUT: only {sb.count}/{total} results scored")
        self.drop_objection()


class Fp8SmokeTest(Fp8BaseTest):
    """Fast default: directed corners + a small random burst, RNE only."""
    N_RANDOM = 120
    OPS = ARITH_OPS
    RMS = [0]


class Fp8ArithTest(Fp8BaseTest):
    """Arithmetic ops (ADD/SUB/MUL/DIV) across all rounding modes."""
    N_RANDOM = 400
    OPS = ARITH_OPS
    RMS = ALL_RMS


class Fp8FullRandomTest(Fp8BaseTest):
    """All 14 opcodes, all rounding modes — the widest constrained-random run."""
    N_RANDOM = 800
    OPS = ALL_OPS
    RMS = ALL_RMS


@cocotb.test()
async def fp8_uvm(dut):
    """cocotb entry point — start the clock and launch the selected UVM test."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    test_name = os.environ.get("TEST", "Fp8SmokeTest")
    await uvm_root().run_test(test_name)
