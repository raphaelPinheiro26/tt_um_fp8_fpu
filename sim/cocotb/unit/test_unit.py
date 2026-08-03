# SPDX-FileCopyrightText: © 2026 Raphael Lopes Pinheiro
# SPDX-License-Identifier: Apache-2.0
#
# Cocotb port of sim/tb_fp8_unit.v.
#
# DUT: tiny_fp8_unit (fp8_controller + fp8_elastic_pipeline). Issue/writeback
# handshakes with a destination-register (rd) tag that must come back, in
# order, alongside each result. Self-checking against Golden_model/vectors.hex
# with random bubbles + back-pressure; also checks the rd FIFO ordering.
import os
import random
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fp8_vectors import load_vectors  # noqa: E402

NVEC = int(os.environ.get("FP8_NVEC", "4000"))
NBP = int(os.environ.get("FP8_NBP", "1500"))
SEED = int(os.environ.get("FP8_SEED", "1"))


async def reset_dut(dut):
    dut.flush.value = 0
    dut.issue_valid.value = 0
    dut.wb_ready.value = 1
    dut.issue_A.value = 0
    dut.issue_B.value = 0
    dut.issue_opcode.value = 0
    dut.issue_rm.value = 0
    dut.issue_rd.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run(dut, vectors, p_valid=100, p_ready=100, seed=0, max_idle=20000):
    rnd = random.Random(seed)
    send_i = 0
    recv_i = 0
    idle = 0
    n = len(vectors)

    while recv_i < n:
        have = send_i < n
        if have:
            a, b, op, rm, res, fl, ex = vectors[send_i]
            rd = (send_i & 0x1F)          # rotating destination-register tag
        else:
            a = b = op = rm = rd = 0

        want_valid = have and (rnd.randint(1, 100) <= p_valid)
        want_ready = rnd.randint(1, 100) <= p_ready

        dut.issue_valid.value = 1 if want_valid else 0
        dut.issue_A.value = a
        dut.issue_B.value = b
        dut.issue_opcode.value = op
        dut.issue_rm.value = rm           # 3-bit port
        dut.issue_rd.value = rd
        dut.wb_ready.value = 1 if want_ready else 0

        await ReadOnly()
        issue_ready = bool(dut.issue_ready.value)
        wb_valid = bool(dut.wb_valid.value)
        g_res = int(dut.wb_result.value)
        g_fl = int(dut.wb_flags.value)
        g_ex = int(dut.wb_exceptions.value)
        g_rd = int(dut.wb_rd.value)

        in_xfer = want_valid and issue_ready
        out_xfer = wb_valid and want_ready

        await RisingEdge(dut.clk)

        progressed = False
        if in_xfer:
            send_i += 1
            progressed = True
        if out_xfer:
            e_a, e_b, e_op, e_rm, e_res, e_fl, e_ex = vectors[recv_i]
            e_rd = recv_i & 0x1F
            assert (g_res, g_fl, g_ex, g_rd) == (e_res, e_fl, e_ex, e_rd), (
                f"mismatch on op #{recv_i} "
                f"(A=0x{e_a:02X} B=0x{e_b:02X} op={e_op} rm={e_rm}): "
                f"got res=0x{g_res:02X} fl={g_fl:07b} ex={g_ex:05b} rd={g_rd} "
                f"exp res=0x{e_res:02X} fl={e_fl:07b} ex={e_ex:05b} rd={e_rd}"
            )
            recv_i += 1
            progressed = True

        idle = 0 if progressed else idle + 1
        assert idle < max_idle, f"deadlock: sent {send_i}/{n}, got {recv_i}/{n}"

    dut.issue_valid.value = 0


@cocotb.test()
async def test_smoke(dut):
    """1.0 + 1.0 = 2.0 through the full unit."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await run(dut, [(0x38, 0x38, 0, 0, 0x40, 0x04, 0x00)])
    dut._log.info("ADD 1.0 + 1.0 -> 2.0 OK")


@cocotb.test()
async def test_golden_full_throughput(dut):
    """Replay golden vectors through controller+pipeline at full throughput."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    vecs = load_vectors(NVEC)
    dut._log.info(f"replaying {len(vecs)} golden vectors (+ rd ordering)")
    await run(dut, vecs, p_valid=100, p_ready=100)
    dut._log.info(f"all {len(vecs)} vectors passed")


@cocotb.test()
async def test_golden_backpressure(dut):
    """Same, with random issue bubbles + writeback back-pressure."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    vecs = load_vectors(NBP)
    dut._log.info(f"back-pressure: {len(vecs)} vectors, p_valid=60 p_ready=55")
    await run(dut, vecs, p_valid=60, p_ready=55, seed=SEED)
    dut._log.info("back-pressure run passed (in-order, rd preserved)")
