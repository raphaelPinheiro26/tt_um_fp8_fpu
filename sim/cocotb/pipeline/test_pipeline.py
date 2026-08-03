# SPDX-FileCopyrightText: © 2026 Raphael Lopes Pinheiro
# SPDX-License-Identifier: Apache-2.0
#
# Cocotb port of sim/tb_fp8_golden.v + sim/tb_fp8_elastic.v +
# sim/tb_fp8_elastic_stream.v.
#
# DUT: fp8_elastic_pipeline (the 4-stage elastic datapath). Two valid/ready
# handshakes: (valid_in, ready_out) in, (valid_out, ready_in) out. Each
# transfer is ONE complete operation, unlike the top wrapper which streams
# bytes. Self-checking against Golden_model/vectors.hex, in order, with
# optional random input bubbles and output back-pressure.
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

_HERE = os.path.dirname(os.path.abspath(__file__))
_COCOTB = os.path.dirname(_HERE)                 # sim/cocotb
_REPO = os.path.dirname(os.path.dirname(_COCOTB))  # repo root
sys.path.insert(0, _COCOTB)
sys.path.insert(0, os.path.join(_REPO, "Golden_model"))
from fp8_vectors import load_vectors  # noqa: E402
from fp8_math import fp8_math          # noqa: E402  (value-exact spec)

NVEC = int(os.environ.get("FP8_NVEC", "4000"))
NBP = int(os.environ.get("FP8_NBP", "1500"))
SEED = int(os.environ.get("FP8_SEED", "1"))


async def reset_dut(dut):
    dut.flush.value = 0
    dut.valid_in.value = 0
    dut.ready_in.value = 1
    dut.A.value = 0
    dut.B.value = 0
    dut.opcode.value = 0
    dut.rounding_mode.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run(dut, vectors, p_valid=100, p_ready=100, seed=0, max_idle=20000):
    """Feed `vectors` through the pipeline with an in-order scoreboard."""
    rnd = random.Random(seed)
    send_i = 0
    recv_i = 0
    idle = 0
    n = len(vectors)

    while recv_i < n:
        have = send_i < n
        if have:
            a, b, op, rm, res, fl, ex = vectors[send_i]
        else:
            a = b = op = rm = 0

        want_valid = have and (rnd.randint(1, 100) <= p_valid)
        want_ready = rnd.randint(1, 100) <= p_ready

        dut.valid_in.value = 1 if want_valid else 0
        dut.A.value = a
        dut.B.value = b
        dut.opcode.value = op
        dut.rounding_mode.value = rm      # 4-bit port, {1'b0, rm[2:0]}
        dut.ready_in.value = 1 if want_ready else 0

        await ReadOnly()
        ready_out = bool(dut.ready_out.value)
        valid_out = bool(dut.valid_out.value)
        g_res = int(dut.result.value)
        g_fl = int(dut.flags.value)
        g_ex = int(dut.exceptions.value)

        in_xfer = want_valid and ready_out
        out_xfer = valid_out and want_ready

        await RisingEdge(dut.clk)

        progressed = False
        if in_xfer:
            send_i += 1
            progressed = True
        if out_xfer:
            e_a, e_b, e_op, e_rm, e_res, e_fl, e_ex = vectors[recv_i]
            assert (g_res, g_fl, g_ex) == (e_res, e_fl, e_ex), (
                f"mismatch on op #{recv_i} "
                f"(A=0x{e_a:02X} B=0x{e_b:02X} op={e_op} rm={e_rm}): "
                f"got res=0x{g_res:02X} fl={g_fl:07b} ex={g_ex:05b} "
                f"exp res=0x{e_res:02X} fl={e_fl:07b} ex={e_ex:05b}"
            )
            recv_i += 1
            progressed = True

        idle = 0 if progressed else idle + 1
        assert idle < max_idle, (
            f"deadlock: sent {send_i}/{n}, got {recv_i}/{n}"
        )

    dut.valid_in.value = 0


@cocotb.test()
async def test_directed_specials(dut):
    """Directed NaN/Inf/zero/subnormal cases (port of tb_fp8_elastic.v)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # (A, B, op, rm); expected result/flags/exc come from the value-exact
    # reference model (Golden_model/fp8_math.py) so the directed cases do not
    # depend on which vectors happen to be committed in vectors.hex.
    cases = [
        (0x38, 0x38, 0, 0),   # 1.0 + 1.0 = 2.0
        (0x40, 0x38, 1, 0),   # 2.0 - 1.0 = 1.0
        (0x78, 0x00, 2, 0),   # Inf * 0 = NaN
        (0x78, 0x40, 2, 0),   # Inf * 2 = Inf
        (0x01, 0x00, 0, 0),   # subnormal + 0
        (0x00, 0x00, 0, 0),   # 0 + 0
        (0x38, 0x00, 3, 0),   # 1.0 / 0 = Inf (div-by-zero)
        (0x79, 0x38, 0, 0),   # NaN + 1.0 = NaN
        (0x77, 0x77, 0, 0),   # overflow -> Inf
    ]
    vecs = []
    for (a, b, op, rm) in cases:
        res, fl, ex = fp8_math(a, b, op, rm)
        vecs.append((a, b, op, rm, res, fl & 0x7F, ex & 0x1F))
    await run(dut, vecs)
    dut._log.info(f"{len(vecs)} directed special cases passed")


@cocotb.test()
async def test_golden_full_throughput(dut):
    """Replay golden vectors at full throughput (port of tb_fp8_golden.v)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    vecs = load_vectors(NVEC)
    dut._log.info(f"replaying {len(vecs)} golden vectors (full throughput)")
    await run(dut, vecs, p_valid=100, p_ready=100)
    dut._log.info(f"all {len(vecs)} vectors passed")


@cocotb.test()
async def test_golden_backpressure(dut):
    """Golden vectors with random bubbles + back-pressure (port of stream tb)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    vecs = load_vectors(NBP)
    dut._log.info(f"back-pressure: {len(vecs)} vectors, p_valid=60 p_ready=55")
    await run(dut, vecs, p_valid=60, p_ready=55, seed=SEED)
    dut._log.info("back-pressure run passed (in-order, no loss/dup)")
