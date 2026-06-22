# SPDX-FileCopyrightText: © 2026 Raphael Lopes Pinheiro
# SPDX-License-Identifier: Apache-2.0
#
# Cocotb test for tt_um_fp8_fpu (FP8 E4M3 FPU), Tiny Tapeout GF 26b shuttle.
#
# This wrapper is the STREAMING / pipelined version (see docs/PROTOCOL.md):
# two independent valid/ready handshakes, several ops in flight.
#
#   ui_in[7:0]   DATA_IN   : byte stream  A -> B -> CTRL   (B/CTRL skipped if sticky)
#   uo_out[7:0]  DATA_OUT  : byte stream  result [-> flags -> exceptions]
#   uio_in[0]    IN_VALID  (host -> chip)
#   uio_out[1]   IN_READY  (chip -> host)
#   uio_out[2]   OUT_VALID (chip -> host)
#   uio_in[3]    OUT_READY (host -> chip)
#   uio_in[4]    STICKY_CTRL : reuse last {rm,opcode}, do NOT send CTRL byte
#   uio_in[5]    STICKY_B    : reuse last B operand,    do NOT send B byte
#   uio_in[6]    READ_FULL   : 3 bytes out (result,flags,exc) instead of 1
#   uio_out[7]   FPU_BUSY
#
# CTRL byte = {rm = ui_in[7:5], opcode = ui_in[4:0]}.
# FP8 E4M3: [7]=sign [6:3]=exp(bias 7) [2:0]=mant. 1.0=0x38, 2.0=0x40.
#
# A transfer happens on the rising clk edge where valid & ready are both 1.
# This test drives the pins exactly like the silicon host would and is
# self-checking against ../Golden_model/vectors.hex
# (columns: A B opcode rm result flags exceptions, all hex).
#
# Knobs (env vars):
#   FP8_NVEC=2000   how many golden vectors to replay (sampled evenly). 0 = all.
#   FP8_NBP=400     how many vectors for the back-pressure test.
#   FP8_SEED=1      RNG seed for the back-pressure bubbles.

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

# --- uio_in bit positions (host -> chip) -----------------------------------
IN_VALID_BIT    = 1 << 0
OUT_READY_BIT   = 1 << 3
STICKY_CTRL_BIT = 1 << 4
STICKY_B_BIT    = 1 << 5
READ_FULL_BIT   = 1 << 6

# --- uio_out bit positions (chip -> host) ----------------------------------
IN_READY_BIT  = 1 << 1
OUT_VALID_BIT = 1 << 2
FPU_BUSY_BIT  = 1 << 7

# --- FLAG / EXC widths (see src/header_fp8.v) ------------------------------
FLAG_MASK = 0x7F  # 7 flag bits
EXC_MASK  = 0x1F  # 5 exception bits

VEC_FILE = os.path.join(os.path.dirname(__file__), "..", "Golden_model", "vectors.hex")

DEFAULT_NVEC = int(os.environ.get("FP8_NVEC", "1500"))
DEFAULT_NBP  = int(os.environ.get("FP8_NBP", "400"))
DEFAULT_SEED = int(os.environ.get("FP8_SEED", "1"))

EXPECTED_UIO_OE = 0b1000_0110


# ---------------------------------------------------------------------------
# Vector loading
# ---------------------------------------------------------------------------
def load_vectors(nvec, op_filter=None, rm_filter=None):
    """Return a list of (a, b, op, rm, res, flags, exc) tuples from vectors.hex.

    If op_filter / rm_filter are given, keep only those rows (read before
    sampling). If nvec > 0 and smaller than the kept set, sample evenly so all
    opcodes / rounding modes stay represented.
    """
    rows = []
    with open(VEC_FILE) as f:
        for line in f:
            p = line.split()
            if len(p) != 7:
                continue
            a, b, op, rm, res, fl, ex = (int(x, 16) for x in p)
            if op_filter is not None and op != op_filter:
                continue
            if rm_filter is not None and rm != rm_filter:
                continue
            rows.append((a, b, op, rm, res, fl, ex))
    total = len(rows)
    if nvec <= 0 or nvec >= total:
        return rows
    stride = total / nvec
    return [rows[int(i * stride)] for i in range(nvec)]


def ctrl_byte(op, rm):
    return ((rm & 0x7) << 5) | (op & 0x1F)


# ---------------------------------------------------------------------------
# Pin helpers
# ---------------------------------------------------------------------------
async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def uio_pack(in_valid, out_ready, sticky_ctrl=False, sticky_b=False, read_full=False):
    v = 0
    if in_valid:    v |= IN_VALID_BIT
    if out_ready:   v |= OUT_READY_BIT
    if sticky_ctrl: v |= STICKY_CTRL_BIT
    if sticky_b:    v |= STICKY_B_BIT
    if read_full:   v |= READ_FULL_BIT
    return v


# ---------------------------------------------------------------------------
# Core streaming engine
#
# `ops` is a list of dicts with keys:
#   bytes_in   : list[int]  the byte(s) to push for this op (A[,B][,CTRL])
#   sticky_ctrl, sticky_b   : the sticky bits to hold for this op's bytes
#   expect     : list[int]  expected output byte(s) for this op (already masked)
# `read_full` is constant for the whole run (output bytes per result).
#
# Drives both handshakes every cycle, predicting transfers at ReadOnly (combos
# settled) and committing state after the RisingEdge. Optional pseudo-random
# bubbles (p_valid) and back-pressure (p_ready) stress the elastic paths.
# Asserts on any mismatch, lost/extra/reordered result, or deadlock.
# ---------------------------------------------------------------------------
async def run_stream(dut, ops, read_full, p_valid=100, p_ready=100,
                     seed=0, max_idle=20000):
    rnd = random.Random(seed)

    # Flatten the input program: one entry per byte, carrying that op's sticky.
    prog = []  # (byte, sticky_ctrl, sticky_b)
    for op in ops:
        for byte in op["bytes_in"]:
            prog.append((byte, op["sticky_ctrl"], op["sticky_b"]))

    expect = [op["expect"] for op in ops]   # list of expected-byte lists
    out_needed = 3 if read_full else 1

    send_i = 0                   # index into prog
    recv_op = 0                  # which op's result we're collecting
    recv_buf = []                # bytes collected for the current result
    results_done = 0
    idle = 0

    while results_done < len(ops):
        have_in = send_i < len(prog)
        if have_in:
            byte, sc, sb = prog[send_i]
        else:
            byte, sc, sb = 0, False, False

        want_valid = have_in and (rnd.randint(1, 100) <= p_valid)
        want_ready = (rnd.randint(1, 100) <= p_ready)

        # Drive this cycle's stimulus.
        dut.ui_in.value = byte
        dut.uio_in.value = uio_pack(want_valid, want_ready, sc, sb, read_full)

        # Let combinational IN_READY / OUT_VALID / DATA_OUT settle, then sample.
        await ReadOnly()
        uio_out = int(dut.uio_out.value)
        in_ready  = bool(uio_out & IN_READY_BIT)
        out_valid = bool(uio_out & OUT_VALID_BIT)
        data_out  = int(dut.uo_out.value)

        in_xfer  = want_valid and in_ready
        out_xfer = out_valid and want_ready

        # Commit at the clock edge.
        await RisingEdge(dut.clk)

        progressed = False
        if in_xfer:
            send_i += 1
            progressed = True
        if out_xfer:
            recv_buf.append(data_out)
            progressed = True
            if len(recv_buf) == out_needed:
                exp = expect[recv_op]
                assert recv_buf == exp, (
                    f"result mismatch on op #{recv_op}: "
                    f"got {[f'0x{b:02X}' for b in recv_buf]} "
                    f"exp {[f'0x{b:02X}' for b in exp]}"
                )
                recv_buf = []
                recv_op += 1
                results_done += 1

        idle = 0 if progressed else idle + 1
        assert idle < max_idle, (
            f"deadlock: no transfer for {idle} cycles "
            f"(sent {send_i}/{len(prog)} bytes, got {results_done}/{len(ops)} results)"
        )

    # Drop valid/ready so the bus is idle at the end.
    dut.uio_in.value = 0


def build_ops_full(vectors):
    """FULL mode: no sticky, READ_FULL=1 -> 3 bytes in, 3 bytes out."""
    ops = []
    for (a, b, op, rm, res, fl, ex) in vectors:
        ops.append({
            "bytes_in": [a, b, ctrl_byte(op, rm)],
            "sticky_ctrl": False,
            "sticky_b": False,
            "expect": [res, fl & FLAG_MASK, ex & EXC_MASK],
        })
    return ops


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_reset_and_idle(dut):
    """After reset the bus is idle: no OUT_VALID, and uio_oe is as specified."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    await ReadOnly()
    assert (int(dut.uio_out.value) & OUT_VALID_BIT) == 0, "OUT_VALID high after reset"
    assert int(dut.uio_oe.value) == EXPECTED_UIO_OE, (
        f"uio_oe = 0b{int(dut.uio_oe.value):08b}, expected 0b{EXPECTED_UIO_OE:08b}"
    )


@cocotb.test()
async def test_add_smoke(dut):
    """Human-readable smoke: 1.0 + 1.0 == 2.0 (0x38 + 0x38 -> 0x40), full mode."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    ops = build_ops_full([(0x38, 0x38, 0, 0, 0x40, 0x04, 0x00)])
    # We only assert on the result byte here; flags/exc are checked by the
    # vector tests against the golden file.
    res_byte = ops[0]["expect"][0]
    assert res_byte == 0x40, "golden file disagrees: 1.0+1.0 should be 0x40"
    await run_stream(dut, ops, read_full=True)
    dut._log.info("ADD 1.0 + 1.0 -> 2.0 OK")


@cocotb.test()
async def test_vectors_streaming(dut):
    """Replay golden vectors at MAX throughput (no bubbles, no back-pressure).

    Producer always feeds, consumer always drains -> keeps the pipeline full
    and checks every result/flags/exc in order.
    """
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    vectors = load_vectors(DEFAULT_NVEC)
    dut._log.info(f"streaming {len(vectors)} golden vectors (full throughput)")
    await run_stream(dut, build_ops_full(vectors), read_full=True,
                     p_valid=100, p_ready=100)
    dut._log.info(f"all {len(vectors)} vectors passed at full throughput")


@cocotb.test()
async def test_vectors_backpressure(dut):
    """Same vectors, but with random input bubbles AND output back-pressure.

    This is the case the old test never exercised: when the host stalls the
    output (OUT_READY low), the result FIFO fills, the pipeline back-pressures,
    and IN_READY drops -- so the wrapper's input deserializer must stall and
    keep results in order. Any loss/dup/reorder is caught by the in-order
    scoreboard inside run_stream().
    """
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)
    vectors = load_vectors(DEFAULT_NBP)
    dut._log.info(f"back-pressure: {len(vectors)} vectors, p_valid=60 p_ready=55")
    await run_stream(dut, build_ops_full(vectors), read_full=True,
                     p_valid=60, p_ready=55, seed=DEFAULT_SEED)
    dut._log.info("back-pressure run passed (in-order, no loss/dup)")


@cocotb.test()
async def test_sticky_ctrl_result_only(dut):
    """Exercise STICKY_CTRL + READ_FULL=0 (2 bytes in / 1 byte out, II~2).

    Reuses one {opcode, rm} across the whole stream and reads only the result
    byte. The first op is sent FULL (sticky low) to load the CTRL register;
    the rest omit CTRL. Validates the sticky reuse path and the 1-byte output.
    """
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await reset_dut(dut)

    # Constant operation: ADD (op=0), round-to-nearest (rm=0).
    OP, RM = 0, 0
    vectors = load_vectors(300, op_filter=OP, rm_filter=RM)
    assert vectors, "no ADD/nearest vectors found in golden file"

    ctrl = ctrl_byte(OP, RM)
    ops = []
    for i, (a, b, op, rm, res, fl, ex) in enumerate(vectors):
        if i == 0:
            # First op: full, sticky low, to load opcode/rm into the holding reg.
            ops.append({
                "bytes_in": [a, b, ctrl],
                "sticky_ctrl": False, "sticky_b": False,
                "expect": [res],            # READ_FULL=0 -> result byte only
            })
        else:
            ops.append({
                "bytes_in": [a, b],         # CTRL reused
                "sticky_ctrl": True, "sticky_b": False,
                "expect": [res],
            })
    dut._log.info(f"sticky_ctrl/result-only: {len(ops)} ADD ops")
    await run_stream(dut, ops, read_full=False, p_valid=100, p_ready=100)
    dut._log.info("sticky_ctrl result-only run passed")
