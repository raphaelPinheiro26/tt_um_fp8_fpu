# UVM track — pyuvm (+ SystemVerilog mirror)

A layered, constrained-random testbench for the streaming top-level, self-checked
against the golden model — real UVM in Python (pyuvm + cocotb), running on
open-source Icarus. A SystemVerilog-UVM mirror is in [`sv_uvm/`](sv_uvm/).

**Full documentation — the real RTL bug it found, architecture, the pyuvm↔SV
cheat-sheet and exercises — is in the wiki:**
[Verification-UVM](../../docs/wiki/Verification-UVM.md).

```sh
pip install -r requirements.txt   # cocotb + pyuvm
cd pyuvm
make                         # smoke
make TEST=Fp8FullRandomTest  # all 14 opcodes, all rounding modes
```
