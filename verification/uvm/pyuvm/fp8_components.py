# ======================================================================
# fp8_components.py — UVM component hierarchy.
#
#   Fp8Driver        pulls items from the sequencer, drives them via the BFM.
#   Fp8CmdMonitor    observes accepted input bytes, publishes Fp8Cmd.
#   Fp8ResultMonitor observes the output byte stream, publishes Fp8Result.
#   Fp8Agent         sequencer + driver + both monitors.
#   Fp8Scoreboard    pairs each command with its result (in order — a property
#                    the formal track proves) and checks against the reference.
#   Fp8Env           agent + scoreboard, wired via analysis ports.
# ======================================================================
import cocotb

from pyuvm import (uvm_agent, uvm_analysis_port, uvm_component, uvm_driver,
                   uvm_env, uvm_monitor, uvm_sequencer, uvm_tlm_analysis_fifo)

from fp8_bfm import Fp8Bfm
from fp8_item import Fp8Cmd, Fp8Result
from fp8_ref import predict


class Fp8Driver(uvm_driver):
    def build_phase(self):
        self.bfm = Fp8Bfm()

    async def run_phase(self):
        await self.bfm.reset()
        self.bfm.start_monitors()
        while True:
            item = await self.seq_item_port.get_next_item()
            await self.bfm.send_op(item.a, item.b, item.op, item.rm)
            self.seq_item_port.item_done()


class Fp8CmdMonitor(uvm_monitor):
    """Reconstructs issued transactions from the DUT input pins."""

    def build_phase(self):
        self.bfm = Fp8Bfm()
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            a, b, op, rm = await self.bfm.get_cmd()
            self.ap.write(Fp8Cmd(a=a, b=b, op=op, rm=rm))


class Fp8ResultMonitor(uvm_monitor):
    """Reconstructs completed results from the DUT output stream."""

    def build_phase(self):
        self.bfm = Fp8Bfm()
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            result, flags, exc = await self.bfm.get_result()
            self.ap.write(Fp8Result(result=result, flags=flags, exc=exc))


class Fp8Agent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = Fp8Driver("driver", self)
        self.cmd_mon = Fp8CmdMonitor("cmd_mon", self)
        self.res_mon = Fp8ResultMonitor("res_mon", self)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


class Fp8Scoreboard(uvm_component):
    def build_phase(self):
        self.cmd_fifo = uvm_tlm_analysis_fifo("cmd_fifo", self)
        self.res_fifo = uvm_tlm_analysis_fifo("res_fifo", self)
        # Exports the env connects the monitors' analysis ports to.
        self.cmd_export = self.cmd_fifo.analysis_export
        self.res_export = self.res_fifo.analysis_export
        self.count = 0
        self.errors = 0

    async def run_phase(self):
        # In-order pairing: each command is matched with the next result. This
        # is only valid because the pipeline preserves order — the very
        # property proven in ../../formal. Formal and UVM reinforce each other.
        while True:
            cmd = await self.cmd_fifo.get()
            res = await self.res_fifo.get()
            exp_r, exp_f, exp_e = predict(cmd.a, cmd.b, cmd.op, cmd.rm)
            self.count += 1
            if (res.result, res.flags, res.exc) != (exp_r, exp_f, exp_e):
                self.errors += 1
                self.logger.error(
                    f"MISMATCH #{self.count} {cmd}: got {res} "
                    f"expected result=0x{exp_r:02X} flags=0x{exp_f:02X} "
                    f"exc=0x{exp_e:02X}")
            else:
                self.logger.debug(f"OK #{self.count} {cmd} -> {res}")

    def check_phase(self):
        if self.errors:
            self.logger.critical(
                f"SCOREBOARD FAILED: {self.errors} mismatch(es) "
                f"over {self.count} operations")
        assert self.errors == 0, f"{self.errors} scoreboard mismatch(es)"


class Fp8Env(uvm_env):
    def build_phase(self):
        self.agent = Fp8Agent("agent", self)
        self.sb = Fp8Scoreboard("sb", self)

    def connect_phase(self):
        self.agent.cmd_mon.ap.connect(self.sb.cmd_export)
        self.agent.res_mon.ap.connect(self.sb.res_export)
