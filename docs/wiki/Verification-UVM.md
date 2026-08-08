# Verification — UVM (pyuvm)

A layered, constrained-random testbench for the streaming top-level, self-checked
against the golden model — real UVM (sequencer/driver/monitor/scoreboard) in
Python via pyuvm + cocotb, so it runs on open-source Icarus (no commercial
simulator). Code: [`verification/uvm/`](../../verification/uvm/); a
SystemVerilog-UVM mirror sits in `verification/uvm/sv_uvm/`.

## The bug it found 🐞

Not a toy testbench — building it surfaced a **real control bug** in the
taped-out RTL that the exhaustive per-operation vectors had missed.

- **Symptom:** `Fp8FullRandomTest` reported isolated mismatches, only on
  `DIV`/`SQRT`, where the DUT result equalled a nearby `SCALB`'s expected result.
- **Root cause:** in `fp8_elastic_pipeline.v` the SCALB fast-path select was
  combinational on the *live* input opcode:
  ```verilog
  wire is_scalb = (opcode == `OPCODE_SCALB);   // BUG: not qualified by n_busy
  ```
  While the iterative divider runs (`ST_BUSY`), the input port carries the *next,
  pending* op. A pending `SCALB` drove `is_scalb` high and hijacked
  `fin_sign/fin_mw/fin_er`, **corrupting the in-flight divide/sqrt result**. The
  neighbouring special-case path was already `n_busy`-qualified; SCALB wasn't.
- **Fix (one line):** `wire is_scalb = ~n_busy & (opcode == `OPCODE_SCALB);`
- **Why sign-off missed it:** `SCALB` was never in `vectors.hex`, so the
  DIV→SCALB interleaving that triggers it never occurred — the bug lives in the
  *interaction between operations*.
- **Validated (Icarus):** 12,500+ random ops across all 14 opcodes pass; a fixed
  seed flips from 7 mismatches to 0; the golden-vector replay (6,000 vectors +
  back-pressure) still passes.

Takeaway: *constrained-random over the full opcode space finds control-path bugs
that even exhaustive per-operation vectors cannot.*

## Why UVM here

The core is already verified exhaustively, so UVM isn't about *more* checking —
it's **methodology**: a standard, reusable component structure (agent / driver /
monitor / sequencer / scoreboard / env / test) that scales from a byte-streaming
FPU to a full SoC. The streaming protocol is a clean bus to practise it on: two
independent `valid/ready` handshakes → a driver that respects back-pressure and a
monitor that reconstructs transactions from pins; a trustworthy reference
(`Golden_model/fp8_math.py`) → a scoreboard with a real oracle; ordered results →
in-order pairing (the property the [formal track](Verification-Formal) proves).

## Architecture

```
sequence → sequencer → driver → BFM → DUT
                                 │ (pins observed)
             cmd monitor ────────┤
             result monitor ─────┴──▶ scoreboard  (predict vs DUT, in order)
```

| File | Role |
|------|------|
| `fp8_bfm.py` | The only layer touching RTL pins. Drives the input byte stream; two pin-level monitors reconstruct commands and results. |
| `fp8_item.py` | Transactions: `Fp8Cmd` (a,b,op,rm) and `Fp8Result` (result,flags,exc). |
| `fp8_seq.py` | `Fp8RandomSeq` (constrained-random) and `Fp8DirectedSeq` (corner cases). |
| `fp8_ref.py` | Scoreboard oracle — thin adapter over `Golden_model/fp8_math.py`. |
| `fp8_components.py` | driver, two monitors, agent, scoreboard, env. |
| `fp8_test.py` | `uvm_test`s + the cocotb entry point. |

Design choices worth noting: the monitor observes **pins, not the driver's
intent** (that's what keeps the check honest); the scoreboard reuses the sign-off
reference as its oracle (no second FP8 implementation to get wrong); command↔
result pairing is **in-order**, sound because the pipeline never reorders (proven
in [Verification-Formal](Verification-Formal) — the two tracks reinforce each
other).

## Run

```sh
pip install -r verification/uvm/requirements.txt   # cocotb + pyuvm
cd verification/uvm/pyuvm
make                         # Fp8SmokeTest (fast: arith ops, RNE)
make TEST=Fp8ArithTest       # ADD/SUB/MUL/DIV, all 5 rounding modes
make TEST=Fp8FullRandomTest  # all 14 opcodes, all rounding modes
make SIM=verilator           # switch simulator
```

A pass ends with the scoreboard reporting 0 mismatches; a failure prints the
exact `A/B/op/rm`, the DUT triple, and the expected triple.

## pyuvm ↔ SystemVerilog UVM cheat-sheet

Everything maps 1:1 onto industry SV-UVM:

| Concept | pyuvm (Python) | SystemVerilog UVM |
|--------|-----------------|-------------------|
| Transaction | `class X(uvm_sequence_item)` | `class x extends uvm_sequence_item;` + `` `uvm_object_utils `` |
| Randomize | Python `random` in `randomize()` | `rand` fields + `constraint` + `.randomize()` |
| Sequence | `class S(uvm_sequence)` / `await body()` | `class s extends uvm_sequence;` / `task body();` |
| start_item | `await self.start_item(it)` | `start_item(it);` |
| Sequencer | `uvm_sequencer("seqr", self)` | `uvm_sequencer#(x)` |
| Driver | `uvm_driver` + `seq_item_port.get_next_item()` | `uvm_driver#(x)` + `seq_item_port.get_next_item()` |
| Monitor | `uvm_monitor` + `uvm_analysis_port` | `uvm_monitor` + `uvm_analysis_port#(x)` |
| Scoreboard | `uvm_component` + `uvm_tlm_analysis_fifo` | `uvm_scoreboard` + `uvm_tlm_analysis_fifo#(x)` |
| Agent/Env/Test | `uvm_agent` / `uvm_env` / `uvm_test` | same class names |
| Phases | `build_phase`, `connect_phase`, `run_phase` (async), `check_phase` | same, `run_phase` is a `task` |
| Objections | `raise_objection()` / `drop_objection()` | `phase.raise_objection(this)` |
| Factory | `uvm_object_utils` implicit | `` `uvm_component_utils(x) `` |
| Run | `await uvm_root().run_test("MyTest")` | `run_test("my_test");` |

Main conceptual differences: pyuvm uses `async`/`await` where SV uses
`task`/`fork-join`, and constraints are Python code instead of a solver. Wiring,
phasing and TLM connections are identical.

## Exercises

1. **Output back-pressure.** The BFM holds `OUT_READY` high; add a coroutine that
   randomly deasserts it and confirm the scoreboard still passes (cf. formal
   `ap_out_persist`).
2. **Sticky operands.** Extend driver/monitor for `STICKY_B` / `STICKY_CTRL`
   (2- and 1-byte ops) and update the `in_needed` logic.
3. **Coverage.** Add a `uvm_subscriber` counting op×rm×result-class bins and drive
   random sequences until coverage closes.
4. **Read the SV mirror.** Open `sv_uvm/` and match each Python class to its
   SystemVerilog twin.
