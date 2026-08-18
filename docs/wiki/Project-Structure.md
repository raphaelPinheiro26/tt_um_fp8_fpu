# Project structure

Where everything lives and why. If you have just cloned this repository, read
this page first — it is written for someone who needs to *change* the project,
not just browse it.

The short version: **`src/` is the silicon, `Golden_model/` is the truth,
everything else exists to prove the two agree.**

---

## The dependency you must understand first

```
Golden_model/fp8_math.py          the SPECIFICATION (exact rational arithmetic)
        │
        │  gen_vectors_math.py enumerates every input
        ▼
Golden_model/vectors*.hex         1,843,968 expected (result, flags, exceptions)
        │
        │  replayed by the testbenches
        ▼
src/*.v                           the IMPLEMENTATION
```

The RTL is never compared against itself or against a previous version of
itself. It is compared against a Python model that computes with `Fraction`,
so it has no rounding error of its own. When the two disagree, the model is
assumed right until proven otherwise.

---

## `Golden_model/` — the reference

| File | Role |
|---|---|
| `fp8_common.py` | Format definition: field layout, opcode numbers, rounding-mode numbers, exact FP8→`Fraction` conversion. **Single source of truth for the opcode numbering** — `header_fp8.v` must agree with it. |
| `fp8_math.py` | The specification. One function per operation, computing the *exact* value and then rounding once. No datapath, no bit tricks. |
| `gen_vectors_math.py` | Enumerates the input space and writes the `.hex` vector files. Knows the arity and rounding-mode dependence of every opcode. |
| `vectors.hex` | Arithmetic + sign ops — 1,311,488 cases |
| `vectors_newops.hex` | The eight extended ops — 527,360 cases |
| `vectors_cvt.hex` | The four integer conversions — 5,120 cases |

Vector file format, 7 hex columns: `A B opcode rm result flags exceptions`.

Regenerate:

```sh
cd Golden_model
python3 gen_vectors_math.py          # -> vectors.hex
python3 gen_vectors_math.py --new    # -> vectors_newops.hex
python3 gen_vectors_math.py --cvt    # -> vectors_cvt.hex
```

> Each flag writes to its **own** file. This was not always true — an earlier
> version defaulted everything to `vectors.hex`, which silently destroyed the
> arithmetic set. `test/regress.sh` now refuses to run if it detects that.

## `src/` — what becomes silicon

Read in this order; it follows the dataflow.

| File | Role |
|---|---|
| `header_fp8.v` | Format, opcodes, flag/exception bit positions, and the three datapath width parameters (`NRM_MW`, `NRM_G`, `NRM_ACCW`). **Start here.** |
| `tt_um_fp8_fpu.v` | Tiny Tapeout top level. Pure protocol adapter: streams operand bytes in and result bytes out over two valid/ready handshakes. Contains no arithmetic. |
| `tiny_fp8_unit.v` | The FPU proper, with the wide interface a CPU would use. This is the block you would attach to a RISC-V core. |
| `fp8_controller.v` | Issue/writeback bookkeeping, destination-register FIFO. |
| `fp8_elastic_pipeline.v` | The elastic datapath: instantiates everything below and wires the pipeline stages. |
| `fp8_handshake_reg.v` | One elastic pipeline register (valid/ready with back-pressure). |
| `fp8_unpack.v` | Splits an FP8 byte into sign/exponent/mantissa + classification flags. |
| `fp8_pre_execute.v` | Special cases resolved by *value*: NaN, Inf, zero, and the ops that bypass the datapath entirely. |
| `fp8_direct_ops.v` | Ops with no arithmetic datapath: min, max, abs, classify, compare, neg, copysign, roundToIntegral, **and fp8→int conversions**. |
| `fp8_execute_comb.v` | The arithmetic: operand pre-normalisation, add/sub alignment, multiply, and the int→fp8 injection point. |
| `fp8_div_iter.v` | Shared iterative unit for divide and square root, 1 digit/cycle. |
| `fp8_normalize.v` | Shared priority encoder + barrel shifter that brings any result to the top of the pre-rounding bus. |
| `fp8_round.v` | Rounding in all five modes, normal/subnormal handling, overflow rules, final flag and exception generation. |
| `config.json` | LibreLane hardening configuration. |

**The three width parameters in `header_fp8.v` are the most consequential
lines in the project.** They were each reduced to their proven floor; see
[Design Decisions](Design-Decisions).

## `test/` — top-level sign-off

The testbench that drives the chip exactly as a host would.

| File | Role |
|---|---|
| `tb.v` | Verilog wrapper instantiating `tt_um_fp8_fpu` (or the gate-level netlist). |
| `test.py` | cocotb tests: reset, smoke, full-throughput vector replay, back-pressure replay, sticky-mode, NEG/COPYSIGN. |
| `Makefile` | RTL and gate-level (`GATES=yes`) builds. |
| **`regress.sh`** | **The sign-off entry point.** Runs every opcode separately so a failure names the guilty instruction. Preflight-checks the toolchain, the vector files and the work directory. |
| `runner.py`, `tb.gtkw` | pytest entry point; GTKWave save file. |

```sh
cd test
JOBS=$(nproc) ./regress.sh                    # RTL,        ~1.84M vectors
GATES=yes JOBS=$(nproc) ./regress.sh          # post-PnR netlist, same set
NVEC=20000 ./regress.sh                       # sampled, for fast iteration
```

## `sim/` — block-level testbenches

| Path | Role |
|---|---|
| `sim/cocotb/{unit,pipeline,controller,handshake}/` | Python testbenches for one block each, so a failure localises without bisecting the whole chip. |
| `sim/cocotb/fp8_vectors.py` | Shared vector loader for those testbenches. |
| `sim/tb_*.v` | The original Verilog testbenches with hand-written directed cases. Superseded by cocotb for sign-off, kept as readable smoke tests and as documentation of intent. |

## `verification/` — the other three layers

Each layer catches something the vectors do not.

| Path | Role |
|---|---|
| `verification/formal/` | SymbiYosys proofs. `*_fv.sv` are the property wrappers, `*.sby` the job files, `run.sh` runs all. Proves **protocol** properties of the elastic pipeline — output persistence, `valid_out` stickiness, liveness — over all inputs and all reachable states. |
| `verification/uvm/pyuvm/` | Constrained-random UVM in Python: `fp8_seq` generates stimulus, `fp8_bfm` drives pins, `fp8_ref` predicts using the *same* golden model, `fp8_components` scoreboards. Generates sequences the vector replay does not. |
| `verification/uvm/sv_uvm/` | SystemVerilog UVM skeleton, for a commercial simulator. |
| `verification/dft/` | Scan-register insertion (`scan_insert.ys`) and flop inventory. |

```sh
source ~/oss-cad-suite/environment
cd verification/formal && ./run.sh

cd verification/uvm/pyuvm && make TEST=Fp8FullRandomTest
```

> **When you add an instruction, all four layers need attention.** Adding the
> conversions initially left the pyuvm opcode pool at `[0..13]` — the random
> testbench was blind to them. That is exactly how the historical SCALB bug
> survived. See [Design Decisions](Design-Decisions).

## `flow/` — physical measurement

| File | Role |
|---|---|
| `collect_metrics.py` | Merges LibreLane's `metrics.json` into one table: area, cells, timing, power, estimated Fmax. |
| `sweep_clock.py` | Re-hardens at several clock periods to find the real Fmax rather than a single-run estimate. |

## `docs/`

`docs/info.md` is the datasheet Tiny Tapeout publishes with the chip — its path
is fixed by the shuttle, it cannot move. Everything else lives in `docs/wiki/`,
which the `docs` workflow publishes to the GitHub Wiki.

## Root

Only three files, all required where they are: `LICENSE`, `README.md` (the
front page and menu) and `info.yaml` (Tiny Tapeout project metadata and
pinout).

---

## Common tasks

| I want to… | Go to |
|---|---|
| Add an operation | `fp8_common.py` → `fp8_math.py` → `gen_vectors_math.py` → `header_fp8.v` → the RTL block → **then audit all four verification layers** |
| Change a datapath width | `header_fp8.v`, then `./regress.sh` to prove bit-exactness |
| Understand the pin protocol | [Pin Protocol](Pin-Protocol) |
| Reproduce the area numbers | [Area Runbook](Area-Runbook) |
| Attach this to a CPU | [RISC-V Integration](RISC-V-Integration) |
| Know why something is the way it is | [Design Decisions](Design-Decisions) |
