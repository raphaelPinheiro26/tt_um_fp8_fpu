# SystemVerilog UVM — reference mirror (didactic)

This folder re-implements the [pyuvm testbench](../pyuvm) in **industry
SystemVerilog UVM**. It exists so you can read the *same* architecture in both
dialects and build fluency with the syntax verification teams actually use.

> **Not run by CI.** Full UVM needs a UVM-capable simulator (Questa/Xcelium/VCS,
> or Verilator's partial UVM support). The open-source, always-green path is the
> pyuvm version. This mirror is validated by *review*, not execution.

## Files

| File | Contents |
|------|----------|
| `fp8_if.sv` | Interface bundling the DUT pins + driver/monitor clocking blocks. |
| `fp8_uvm_pkg.sv` | All UVM classes: items, sequence, driver, two monitors, scoreboard, agent, env, tests. |
| `tb_top.sv` | Top: clock, reset, DUT instance, `uvm_config_db` set, `run_test`. |

## How it maps to pyuvm

Every class here has a Python twin — see the cheat-sheet table in
[../README.md](../README.md). The one-to-one correspondence:

- `fp8_cmd` / `fp8_result` ↔ `Fp8Cmd` / `Fp8Result`
- `fp8_random_seq` (with `constraint`/`randomize`) ↔ `Fp8RandomSeq` (Python `random`)
- `fp8_driver` ↔ `Fp8Driver` + `Fp8Bfm.send_op`
- `fp8_cmd_monitor` / `fp8_result_monitor` ↔ `Fp8CmdMonitor` / `Fp8ResultMonitor` (+ the pin-snooping in `Fp8Bfm`)
- `fp8_scoreboard` ↔ `Fp8Scoreboard`
- `fp8_agent` / `fp8_env` / `fp8_base_test` ↔ `Fp8Agent` / `Fp8Env` / `Fp8BaseTest`

The instructive differences to notice while reading:

- **Concurrency.** SV uses `task` + `@(clocking)` + implicit `forever`; pyuvm
  uses `async def` + `await`. The `run_phase` shape is otherwise identical.
- **Randomization.** SV has a real constraint solver (`rand` + `constraint` +
  `randomize() with {...}`); pyuvm randomizes in plain Python.
- **TLM wiring.** SV needs `` `uvm_analysis_imp_decl `` to give the scoreboard two
  distinct `write` methods (`write_cmd`, `write_res`); pyuvm uses two
  `uvm_tlm_analysis_fifo`s and `await fifo.get()`.
- **Oracle.** This mirror loads `Golden_model/vectors.hex` into an associative
  array (like `sim/tb_fp8_golden.v`); the pyuvm version calls the exact
  `fp8_math` model directly. Both are the same sign-off reference. (The default
  `vectors.hex` covers ADD/SUB/MUL/DIV/NEG/COPYSIGN; the scoreboard silently
  skips ops with no golden entry, so extend the vector file to score the rest.)
