# ======================================================================
# fp8_bfm.py — Bus Functional Model for the tt_um_fp8_fpu streaming pins.
#
# This is the ONLY layer that touches the RTL pins. It exposes a clean,
# transaction-level API to the UVM components above it:
#
#   await bfm.reset()                       # drive rst_n / config pins
#   bfm.start_monitors()                    # spawn pin-level monitors
#   await bfm.send_op(a, b, op, rm)         # DRIVER path (drives input stream)
#   cmd  = await bfm.get_cmd()              # COMMAND monitor output (from pins)
#   res  = await bfm.get_result()           # RESULT monitor output (from pins)
#
# Protocol (see ../../../docs/PROTOCOL.md and src/tt_um_fp8_fpu.v):
#   Config used here: STICKY_CTRL=0, STICKY_B=0, READ_FULL=1.
#     -> every op sends 3 input bytes:  A, B, CTRL
#     -> every result returns 3 bytes:  result, flags, exceptions
#   CTRL byte = { rm[2:0]=ui_in[7:5], opcode[4:0]=ui_in[4:0] }.
#   OUT_READY is held high (no output back-pressure in the base test); adding
#   random back-pressure is a documented exercise in the README.
# ======================================================================
import cocotb
from cocotb.queue import Queue
from cocotb.triggers import ReadOnly, RisingEdge

from pyuvm import utility_classes


# uio_in bit positions (host-driven control), from the pin map in the wrapper.
IN_VALID_BIT = 0
OUT_READY_BIT = 3
STICKY_CTRL_BIT = 4
STICKY_B_BIT = 5
READ_FULL_BIT = 6
# uio_out bit positions (DUT-driven status).
IN_READY_BIT = 1
OUT_VALID_BIT = 2
FPU_BUSY_BIT = 7

# Base uio_in value: OUT_READY=1, READ_FULL=1, sticky bits low, IN_VALID=0.
BASE_UIO = (1 << OUT_READY_BIT) | (1 << READ_FULL_BIT)


def _bit(value, pos):
    return (int(value) >> pos) & 1


class Fp8Bfm(metaclass=utility_classes.Singleton):
    """Singleton BFM bound to the cocotb top-level DUT."""

    def __init__(self):
        self.dut = cocotb.top
        self.cmd_q = Queue(maxsize=0)      # reconstructed input transactions
        self.result_q = Queue(maxsize=0)   # reconstructed output transactions

    # ------------------------------------------------------------------
    # Reset + config
    # ------------------------------------------------------------------
    async def reset(self):
        self.dut.ui_in.value = 0
        self.dut.uio_in.value = BASE_UIO
        self.dut.ena.value = 1
        self.dut.rst_n.value = 0
        for _ in range(5):
            await RisingEdge(self.dut.clk)
        self.dut.rst_n.value = 1
        await RisingEdge(self.dut.clk)

    # ------------------------------------------------------------------
    # DRIVER path — serialise one operation onto the input byte stream.
    # ------------------------------------------------------------------
    async def send_op(self, a, b, op, rm):
        ctrl = ((rm & 0x7) << 5) | (op & 0x1F)
        for byte in (a & 0xFF, b & 0xFF, ctrl):
            await self._drive_byte(byte)
        # Deassert IN_VALID between operations (keep config/OUT_READY stable).
        self.dut.uio_in.value = BASE_UIO

    async def _drive_byte(self, byte):
        """Drive one byte and hold IN_VALID until the core accepts it."""
        self.dut.ui_in.value = byte
        self.dut.uio_in.value = BASE_UIO | (1 << IN_VALID_BIT)
        while True:
            await ReadOnly()                       # let combinational settle
            accepted = _bit(self.dut.uio_out.value, IN_READY_BIT)
            await RisingEdge(self.dut.clk)          # this edge takes the byte...
            if accepted:                            # ...iff IN_READY was high
                return

    # ------------------------------------------------------------------
    # MONITORS — independent of the driver; observe the pins only.
    # ------------------------------------------------------------------
    def start_monitors(self):
        cocotb.start_soon(self._cmd_monitor())
        cocotb.start_soon(self._result_monitor())

    async def _cmd_monitor(self):
        """Reconstruct (a, b, op, rm) from accepted input bytes.

        Sample in the ReadOnly region BEFORE the clock edge: the values present
        then are exactly the ones the upcoming edge consumes on a valid&&ready
        transfer. Sampling after the edge would read the next byte the driver
        has already begun presenting (an off-by-one that scrambles the stream).
        """
        collected = []
        while True:
            await ReadOnly()
            if _bit(self.dut.rst_n.value, 0) == 0:
                collected = []
            else:
                in_valid = _bit(self.dut.uio_in.value, IN_VALID_BIT)
                in_ready = _bit(self.dut.uio_out.value, IN_READY_BIT)
                if in_valid and in_ready:           # a byte transfers on this edge
                    collected.append(int(self.dut.ui_in.value))
                    if len(collected) == 3:         # A, B, CTRL
                        a, b, ctrl = collected
                        op = ctrl & 0x1F
                        rm = (ctrl >> 5) & 0x7
                        self.cmd_q.put_nowait((a, b, op, rm))
                        collected = []
            await RisingEdge(self.dut.clk)

    async def _result_monitor(self):
        """Reconstruct (result, flags, exc) from the output byte stream.

        Same ReadOnly-before-edge sampling discipline as the command monitor.
        """
        collected = []
        while True:
            await ReadOnly()
            if _bit(self.dut.rst_n.value, 0) == 0:
                collected = []
            else:
                out_valid = _bit(self.dut.uio_out.value, OUT_VALID_BIT)
                out_ready = _bit(self.dut.uio_in.value, OUT_READY_BIT)
                if out_valid and out_ready:         # a byte transfers on this edge
                    collected.append(int(self.dut.uo_out.value))
                    if len(collected) == 3:         # result, flags, exc
                        result, flags, exc = collected
                        self.result_q.put_nowait(
                            (result & 0xFF, flags & 0x7F, exc & 0x1F))
                        collected = []
            await RisingEdge(self.dut.clk)

    async def get_cmd(self):
        return await self.cmd_q.get()

    async def get_result(self):
        return await self.result_q.get()
