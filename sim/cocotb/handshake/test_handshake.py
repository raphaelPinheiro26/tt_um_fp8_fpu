# SPDX-FileCopyrightText: © 2026 Raphael Lopes Pinheiro
# SPDX-License-Identifier: Apache-2.0
#
# Cocotb port of sim/tb_handshake_elastic.v.
#
# DUT: fp8_handshake_reg (the elastic skid-buffer that separates every pipeline
# stage), instantiated with DATA_WIDTH=8 (see Makefile -P override). Pushes an
# increasing counter through with random input bubbles and output back-pressure
# and asserts the output stream is byte-exact and IN ORDER -- no loss, no
# duplication, no reordering. This is the property that broke in the original
# skid buffer and was fixed (see the header of src/fp8_handshake_reg.v).
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

WIDTH = 8
MASK = (1 << WIDTH) - 1
N = int(os.environ.get("FP8_N", "4000"))
SEED = int(os.environ.get("FP8_SEED", "1"))


async def reset_dut(dut):
    dut.flush.value = 0
    dut.valid_in.value = 0
    dut.ready_in.value = 1
    dut.data_in.value = 0
    dut.rst.value = 1
    await ClockCycles(dut.clk, 4)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def stream_in_order(dut, n, p_valid, p_ready, seed):
    rnd = random.Random(seed)
    send = 0          # next value to push (1..n)
    expect = 0        # next value we must observe (1..n)
    idle = 0
    while expect < n:
        have = send < n
        val = ((send + 1) & MASK) if have else 0
        want_valid = have and (rnd.randint(1, 100) <= p_valid)
        want_ready = rnd.randint(1, 100) <= p_ready

        dut.valid_in.value = 1 if want_valid else 0
        dut.data_in.value = val
        dut.ready_in.value = 1 if want_ready else 0

        await ReadOnly()
        ready_out = bool(dut.ready_out.value)
        valid_out = bool(dut.valid_out.value)
        data_out = int(dut.data_out.value)

        in_xfer = want_valid and ready_out
        out_xfer = valid_out and want_ready

        await RisingEdge(dut.clk)

        progressed = False
        if in_xfer:
            send += 1
            progressed = True
        if out_xfer:
            exp = (expect + 1) & MASK
            assert data_out == exp, (
                f"REORDER/LOSS/DUP: got 0x{data_out:02X} expected 0x{exp:02X} "
                f"(item #{expect + 1})"
            )
            expect += 1
            progressed = True

        idle = 0 if progressed else idle + 1
        assert idle < 10000, f"deadlock: sent {send}/{n}, recv {expect}/{n}"

    dut.valid_in.value = 0


@cocotb.test()
async def test_full_throughput(dut):
    """No bubbles, no back-pressure: 1 item/cycle when full."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await stream_in_order(dut, N, p_valid=100, p_ready=100, seed=SEED)
    dut._log.info(f"{N} items streamed in order at full throughput")


@cocotb.test()
async def test_random_backpressure(dut):
    """Random input bubbles + output back-pressure: still in order."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await stream_in_order(dut, N, p_valid=55, p_ready=50, seed=SEED + 7)
    dut._log.info(f"{N} items in order under random bubbles/back-pressure")


@cocotb.test()
async def test_flush(dut):
    """flush drops in-flight data: valid_out is low the cycle after flush."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    # Fill both output reg and skid, with the consumer stalled.
    dut.ready_in.value = 0
    dut.valid_in.value = 1
    dut.data_in.value = 0xA5
    await RisingEdge(dut.clk)
    dut.data_in.value = 0x5A
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    dut.flush.value = 1
    await RisingEdge(dut.clk)
    dut.flush.value = 0
    await ReadOnly()
    assert bool(dut.valid_out.value) is False, "valid_out high after flush"
    dut._log.info("flush cleared the elastic register")
