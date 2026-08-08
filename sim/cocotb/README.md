# sim/cocotb/ — module-level cocotb testbenches

Python/cocotb ports of the legacy Verilog TBs, one per building block
(`handshake/`, `pipeline/`, `unit/`, `controller/`) — for local block-level
debugging and regression. Not part of the Tiny Tapeout flow (only `../../test/`
is). `fp8_vectors.py` locates `Golden_model/vectors.hex`.

**Full documentation — what each suite checks and the environment knobs — is in
the wiki:**
[Simulation & Tests](../../docs/wiki/Simulation-and-Tests.md#block-level-cocotb--simcocotb).

```sh
python3 Golden_model/gen_vectors_math.py   # once, from the repo root
cd sim/cocotb/pipeline && make             # also: unit, handshake, controller
```
