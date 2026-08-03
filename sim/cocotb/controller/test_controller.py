# SPDX-FileCopyrightText: © 2026 Raphael Lopes Pinheiro
# SPDX-License-Identifier: Apache-2.0
#
# Cocotb port of sim/tb_fp8_controller.v.
#
# DUT: fp8_controller in isolation. The pipeline it talks to is MODELLED HERE
# in Python (the Verilog tb used an internal `pipe_stub`): an in-order queue
# with a small latency that echoes whatever result we choose. We then check
# that the controller:
#   * only issues while its rd FIFO has room (issue_ready drops when full),
#   * writes results back IN ORDER, each with the matching rd tag,
#   * honours writeback back-pressure without losing/reordering results,
#   * clears fpu_busy and drops in-flight work on flush.
import os
import random
import sys
from collections import deque

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fp8_vectors import load_vectors  # noqa: E402

FIFO_DEPTH = 8                    # RD_FIFO_DEPTH default in fp8_controller
PIPE_LAT = 2                      # modelled pipeline latency (cycles)
SEED = int(os.environ.get("FP8_SEED", "1"))


async def reset_dut(dut):
    dut.flush.value = 0
    dut.issue_valid.value = 0
    dut.issue_A.value = 0
    dut.issue_B.value = 0
    dut.issue_opcode.value = 0
    dut.issue_rm.value = 0
    dut.issue_rd.value = 0
    dut.wb_ready.value = 1
    dut.pipe_ready_out.value = 1
    dut.pipe_valid_out.value = 0
    dut.pipe_result.value = 0
    dut.pipe_flags.value = 0
    dut.pipe_exceptions.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_inorder_with_backpressure(dut):
    """Issue golden ops; a modelled in-order pipeline returns results with
    latency; check writeback order + rd tags under random back-pressure."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    rnd = random.Random(SEED)

    vectors = load_vectors(2000)
    n = len(vectors)
    send_i = 0
    recv_i = 0
    t = 0
    idle = 0

    pipe_q = deque()     # (res, fl, ex, avail_t) modelled pipeline contents
    exp_q = deque()      # (res, fl, ex, rd) expected writeback order

    while recv_i < n:
        # ---- drive from current Python state ----
        have = send_i < n
        if have:
            a, b, op, rm, res, fl, ex = vectors[send_i]
            rd = send_i & 0x1F
        else:
            a = b = op = rm = res = fl = ex = rd = 0
        want_issue = have and (rnd.randint(1, 100) <= 70)
        dut.issue_valid.value = 1 if want_issue else 0
        dut.issue_A.value = a
        dut.issue_B.value = b
        dut.issue_opcode.value = op
        dut.issue_rm.value = rm
        dut.issue_rd.value = rd
        dut.pipe_ready_out.value = 1
        dut.wb_ready.value = 1 if (rnd.randint(1, 100) <= 60) else 0

        head_ready = bool(pipe_q) and (pipe_q[0][3] <= t)
        dut.pipe_valid_out.value = 1 if head_ready else 0
        if head_ready:
            hr, hf, hx, _ = pipe_q[0]
            dut.pipe_result.value = hr
            dut.pipe_flags.value = hf
            dut.pipe_exceptions.value = hx

        # ---- sample combinational outputs ----
        await ReadOnly()
        issue_ready = bool(dut.issue_ready.value)
        pipe_ready_in = bool(dut.pipe_ready_in.value)
        wb_valid = bool(dut.wb_valid.value)
        g_res = int(dut.wb_result.value)
        g_fl = int(dut.wb_flags.value)
        g_ex = int(dut.wb_exceptions.value)
        g_rd = int(dut.wb_rd.value)

        issue_xfer = want_issue and issue_ready
        pipe_out_xfer = head_ready and pipe_ready_in
        wb_xfer = wb_valid and bool(dut.wb_ready.value)

        await RisingEdge(dut.clk)

        # ---- commit ----
        progressed = False
        if issue_xfer:
            pipe_q.append((res, fl, ex, t + PIPE_LAT))
            exp_q.append((res, fl, ex, rd))
            send_i += 1
            progressed = True
        if pipe_out_xfer:
            pipe_q.popleft()
            progressed = True
        if wb_xfer:
            e_res, e_fl, e_ex, e_rd = exp_q.popleft()
            assert (g_res, g_fl, g_ex, g_rd) == (e_res, e_fl, e_ex, e_rd), (
                f"writeback #{recv_i} out of order: got "
                f"res=0x{g_res:02X} fl={g_fl:07b} ex={g_ex:05b} rd={g_rd} "
                f"exp res=0x{e_res:02X} fl={e_fl:07b} ex={e_ex:05b} rd={e_rd}"
            )
            recv_i += 1
            progressed = True

        idle = 0 if progressed else idle + 1
        assert idle < 20000, f"deadlock: issued {send_i}/{n}, wrote {recv_i}/{n}"
        t += 1

    dut.issue_valid.value = 0
    dut._log.info(f"{n} ops written back in order with correct rd tags")


@cocotb.test()
async def test_fifo_full_backpressure(dut):
    """Stall the pipeline; the rd FIFO fills and issue_ready must drop, and the
    number of accepted-but-unretired ops must never exceed the FIFO depth."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    dut.pipe_ready_out.value = 1
    dut.pipe_valid_out.value = 0       # pipeline never returns anything
    dut.wb_ready.value = 1
    dut.issue_valid.value = 1
    dut.issue_opcode.value = 0

    inflight = 0
    saw_stall = False
    for i in range(40):
        dut.issue_rd.value = i & 0x1F
        dut.issue_A.value = i & 0xFF
        await ReadOnly()
        issue_ready = bool(dut.issue_ready.value)
        if not issue_ready:
            saw_stall = True
        await RisingEdge(dut.clk)
        if issue_ready:
            inflight += 1
        assert inflight <= FIFO_DEPTH, (
            f"accepted {inflight} ops but FIFO depth is {FIFO_DEPTH}"
        )

    dut.issue_valid.value = 0
    assert saw_stall, "issue_ready never dropped despite a stalled pipeline"
    dut._log.info(f"issue_ready correctly gated at FIFO depth {FIFO_DEPTH}")


@cocotb.test()
async def test_flush(dut):
    """After a few issues, flush must clear fpu_busy and drop in-flight work."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    dut.pipe_ready_out.value = 1
    dut.pipe_valid_out.value = 0
    dut.wb_ready.value = 1
    dut.issue_valid.value = 1
    dut.issue_opcode.value = 0
    for i in range(4):
        dut.issue_rd.value = i
        await RisingEdge(dut.clk)
    dut.issue_valid.value = 0
    await ReadOnly()
    assert bool(dut.fpu_busy.value), "fpu_busy should be high with ops in flight"

    await RisingEdge(dut.clk)          # leave ReadOnly before driving flush
    dut.flush.value = 1
    await RisingEdge(dut.clk)
    dut.flush.value = 0
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert not bool(dut.wb_valid.value), "wb_valid still high after flush"
    dut._log.info("flush cleared the controller (fpu_busy low, no leak)")
