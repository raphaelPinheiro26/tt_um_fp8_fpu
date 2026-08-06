# UVM Track — pyuvm (runnable) + SystemVerilog UVM (reference)

> Build a **layered, reusable, constrained-random** testbench for the FP8
> streaming top-level, self-checked against the golden model. The runnable
> version uses **pyuvm** (pure open source: Python + cocotb + Icarus/Verilator).
> The [`sv_uvm/`](sv_uvm/) folder mirrors the same architecture in real
> SystemVerilog UVM so you can read both dialects side by side.

## What this testbench found (a real RTL bug)

This is not a toy testbench — building it surfaced a genuine control bug in the
taped-out RTL that the exhaustive golden-vector sign-off had missed.

**Symptom.** `Fp8FullRandomTest` (all 14 opcodes, constrained-random) reported
isolated mismatches, *only* on `DIV`/`SQRT`, where the DUT result equalled the
expected result of a nearby `SCALB` operation.

**Root cause.** In `fp8_elastic_pipeline.v`, the SCALB fast-path select was
combinational on the *live* input opcode:

```verilog
wire is_scalb = (opcode == `OPCODE_SCALB);   // BUG: not qualified by n_busy
```

While the iterative divider runs (`ST_BUSY`), the input port still carries the
*next, pending* operation. If that pending op was `SCALB`, `is_scalb` went high
and hijacked `fin_sign/fin_mw/fin_er`, **corrupting the divide/sqrt result being
written into the pipeline register**. The neighbouring special-case path
(`tok_*`) was already `n_busy`-qualified; the SCALB path was not. One-line fix:

```verilog
wire is_scalb = ~n_busy & (opcode == `OPCODE_SCALB);
```

**Why sign-off missed it.** The golden `vectors.hex` only covers
ADD/SUB/MUL/DIV/NEG/COPYSIGN — `SCALB` was never issued *during* an in-flight
divide, so the interleaving that triggers the bug never occurred.

**Validation of the fix (executed with Icarus Verilog):** the one-line change
makes 12,500+ random operations across all 14 opcodes pass with zero
mismatches, deterministically flips a fixed-seed run from 7 mismatches to 0, and
does **not** regress the existing golden-vector pipeline replay (6,000 vectors +
back-pressure, all pass). The methodology lesson: *constrained-random over the
full opcode space finds control-path bugs that even exhaustive per-operation
vectors cannot, because the bug lives in the interaction between operations.*

## Why UVM here

The taped-out core is verified exhaustively already — so why a UVM layer? Because
UVM is not about *more* checking, it is about **methodology**: a standard,
reusable component structure (agent / driver / monitor / sequencer / scoreboard
/ env / test) that scales from a byte-streaming FPU to a full SoC, and that
every verification team expects you to know. The `tt_um_fp8_fpu` streaming
protocol is a clean, self-contained bus to practise it on:

- two independent `valid/ready` handshakes → a **driver** that respects
  back-pressure and a **monitor** that reconstructs transactions from pins;
- a trustworthy reference (`Golden_model/fp8_math.py`) → a **scoreboard** with a
  real oracle instead of a hand-rolled one;
- ordered, pipelined results → in-order command/result pairing (the exact
  property the [formal track](../formal) proves — the two tracks reinforce
  each other).

## Prerequisites & run

```bash
pip install -r ../requirements.txt         # cocotb + pyuvm
# plus a simulator: iverilog (apt install iverilog) or verilator

cd pyuvm
make                        # Fp8SmokeTest  (fast: arith ops, RNE)
make TEST=Fp8ArithTest      # ADD/SUB/MUL/DIV, all 5 rounding modes
make TEST=Fp8FullRandomTest # all 14 opcodes, all rounding modes
make SIM=verilator          # switch simulator
```

A pass ends with the scoreboard reporting 0 mismatches; a failure prints the
exact `A/B/op/rm`, the DUT triple, and the expected triple.

## Architecture

```
                         Fp8Env
   ┌───────────────────────────────────────────────────────────┐
   │  Fp8Agent                                                   │
   │  ┌───────────┐  seq_item  ┌───────────┐   pins  ┌────────┐  │
   │  │ sequencer │───────────▶│  driver   │────────▶│  BFM   │──┼──▶ DUT
   │  └───────────┘            └───────────┘         │(pins)  │  │
   │        ▲                                        └────────┘  │
   │  Fp8RandomSeq / Fp8DirectedSeq                     │ observes│
   │                                                    ▼         │
   │  ┌───────────────┐   ap(Fp8Cmd)   ┌──────────────────────┐  │
   │  │ Fp8CmdMonitor │───────────────▶│                      │  │
   │  └───────────────┘                │    Fp8Scoreboard     │  │
   │  ┌────────────────┐  ap(Fp8Result)│  predict() vs DUT    │  │
   │  │ Fp8ResultMonitor│──────────────▶│  (in-order pairing)  │  │
   │  └────────────────┘               └──────────────────────┘  │
   └───────────────────────────────────────────────────────────┘
```

| File | Role |
|------|------|
| `fp8_bfm.py` | The only layer touching RTL pins. Drives the input byte stream; two independent pin-level monitors reconstruct commands and results. |
| `fp8_item.py` | Transactions: `Fp8Cmd` (a,b,op,rm) and `Fp8Result` (result,flags,exc). |
| `fp8_seq.py` | `Fp8RandomSeq` (constrained-random) and `Fp8DirectedSeq` (corner cases). |
| `fp8_ref.py` | Scoreboard oracle — thin adapter over `Golden_model/fp8_math.py`. |
| `fp8_components.py` | driver, two monitors, agent, scoreboard, env. |
| `fp8_test.py` | `uvm_test`s + the cocotb entry point. |

### Design choices worth noting

- **The monitor observes pins, not the driver's intent.** `Fp8CmdMonitor`
  reconstructs each operation from the accepted `ui_in` bytes and the
  `IN_VALID/IN_READY` handshake — it does not peek at what the sequence sent.
  That is what makes a monitor a *monitor* and keeps the check honest.
- **Reuse the sign-off reference as the oracle.** `fp8_ref.predict` calls the
  same exact-`Fraction` model the RTL was audited against. Re-implementing FP8
  math in the scoreboard would just add a second thing to get wrong. *(Verified:
  `predict` reproduces `Golden_model/vectors.hex` exactly.)*
- **In-order pairing.** The scoreboard matches command *N* with result *N*.
  That is only sound because the pipeline never reorders — proven in
  [`../formal`](../formal). Formal supplies the assumption the scoreboard relies on.

## pyuvm ↔ SystemVerilog UVM cheat-sheet

Everything you learn here maps 1:1 onto industry SystemVerilog UVM:

| Concept | pyuvm (Python) | SystemVerilog UVM |
|--------|-----------------|-------------------|
| Transaction | `class X(uvm_sequence_item)` | `class x extends uvm_sequence_item;` + `` `uvm_object_utils `` |
| Randomize | Python `random` in `randomize()` | `rand` fields + `constraint` blocks + `.randomize()` |
| Sequence | `class S(uvm_sequence)` / `await body()` | `class s extends uvm_sequence;` / `task body();` |
| start_item | `await self.start_item(it)` | `start_item(it);` |
| Sequencer | `uvm_sequencer("seqr", self)` | `uvm_sequencer#(x)` |
| Driver | `uvm_driver` + `seq_item_port.get_next_item()` | `uvm_driver#(x)` + `seq_item_port.get_next_item()` |
| Monitor | `uvm_monitor` + `uvm_analysis_port` | `uvm_monitor` + `uvm_analysis_port#(x)` |
| Scoreboard | `uvm_component` + `uvm_tlm_analysis_fifo` | `uvm_scoreboard` + `uvm_tlm_analysis_fifo#(x)` |
| Agent/Env/Test | `uvm_agent` / `uvm_env` / `uvm_test` | same class names |
| Phases | `build_phase`, `connect_phase`, `run_phase` (async), `check_phase` | same, `run_phase` is a `task` |
| Objections | `self.raise_objection()` / `drop_objection()` | `phase.raise_objection(this)` |
| Config DB | `ConfigDB()` / `uvm_root()` | `uvm_config_db#(T)` / `uvm_root` |
| Factory | `uvm_object_utils` implicit | `` `uvm_component_utils(x) `` |
| Run | `await uvm_root().run_test("MyTest")` | `run_test("my_test");` |

The main *conceptual* differences: pyuvm uses Python `async`/`await` where SV uses
`task`/`@`/`fork-join`, and constraints are Python code instead of a dedicated
solver. The component wiring, phasing, and TLM connections are identical.

## Suggested exercises

1. **Output back-pressure.** The BFM holds `OUT_READY` high. Add a coroutine
   that randomly deasserts it and confirm the scoreboard still passes (results
   must not be lost — cf. the formal `ap_out_persist` property).
2. **Sticky operands.** Extend the driver/monitor to exercise `STICKY_B` /
   `STICKY_CTRL` mode (2- and 1-byte operations) and update `in_needed` logic.
3. **Coverage.** Add functional coverage (a `uvm_subscriber` counting op×rm×
   result-class bins) and drive random sequences until coverage closes.
4. **Read the SV mirror.** Open [`sv_uvm/`](sv_uvm/) and match each Python class
   to its SystemVerilog twin; note where `async`/`await` replaces `task`/`fork`.
