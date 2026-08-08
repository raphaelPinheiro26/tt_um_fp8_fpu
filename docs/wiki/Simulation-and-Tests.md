# Simulation & Tests

Everything simulation: the official cocotb suite Tiny Tapeout runs, the
block-level cocotb tests, the legacy Verilog testbenches, and the golden
reference model they all check against.

## Official cocotb suite — [`test/`](../../test/)

The suite Tiny Tapeout runs on every push. It drives the streaming pins exactly
like a silicon host and self-checks result/flags/exceptions in order.

```sh
cd test && make -B          # expect: TESTS=6 PASS=6 FAIL=0
```

The six tests: reset/idle, a readable `1.0 + 1.0 == 2.0` smoke, a full-throughput
golden-vector stream, the same vectors with random bubbles + output
back-pressure, and a sticky-mode (`STICKY_CTRL`, `READ_FULL=0`) case. Knobs:

```sh
FP8_NVEC=5000 make    # streaming test: N vectors (0 = all in the file)
FP8_NBP=1000 make     # back-pressure test: N vectors
FP8_SEED=7 make       # back-pressure RNG seed
```

Gate-level sim after hardening: copy the netlist to `gate_level_netlist.v` and
run `make -B GATES=yes`. Waveforms land in `test/tb.fst` (open with
`gtkwave test/tb.fst tb.gtkw` or `surfer test/tb.fst`). On native Windows without
`make`, `python test/runner.py` mirrors the Makefile.

## Block-level cocotb — [`sim/cocotb/`](../../sim/cocotb/)

Python/cocotb ports of the legacy Verilog TBs, one per building block (not part
of the TT flow — local block debugging/regression):

| Directory | DUT | Checks |
|-----------|-----|--------|
| `handshake/` | `fp8_handshake_reg` | counter through the skid buffer with random bubbles/back-pressure — byte-exact, in order, plus `flush` |
| `pipeline/` | `fp8_elastic_pipeline` | directed NaN/Inf/zero/subnormal + golden replay, full throughput and under back-pressure |
| `unit/` | `tiny_fp8_unit` | golden replay through controller+pipeline; checks the `rd` tag returns in order |
| `controller/` | `fp8_controller` | issue interface vs a Python pipeline model; in-order writeback, rd-FIFO full/stall, `flush` |

```sh
python3 Golden_model/gen_vectors_math.py   # once, writes Golden_model/vectors.hex
cd sim/cocotb/pipeline && make             # also: unit, handshake, controller
```

Knobs: `FP8_NVEC` (full-throughput vectors, default 4000), `FP8_NBP`
(back-pressure vectors, 1500), `FP8_N` (handshake items, 4000), `FP8_SEED` (RNG,
1), `FP8_VEC` (explicit `vectors.hex` path). `fp8_vectors.py` is the shared helper
that locates the golden vectors.

## Legacy Verilog testbenches — [`sim/`](../../sim/)

The original stand-alone Verilog TBs, kept for reference and quick local
debugging (**not** part of the TT flow):

| Testbench | Exercises |
|-----------|-----------|
| `tb_fp8_unit.v` | full `tiny_fp8_unit` (controller + pipeline) |
| `tb_fp8_controller.v` | `fp8_controller` issue/writeback + rd FIFO |
| `tb_fp8_elastic.v` | `fp8_elastic_pipeline` handshake |
| `tb_fp8_elastic_stream.v` | streaming throughput on the elastic pipeline |
| `tb_handshake_elastic.v` | the `fp8_handshake_reg` building block |
| `tb_fp8_golden.v` | **self-checking** replay of `vectors.hex` |

Run from the repo root (so the golden TB finds `vectors.hex`), pointing the
compiler at `src/` with `-I`:

```sh
iverilog -g2012 -I src -o sim/golden.out \
    sim/tb_fp8_golden.v \
    src/tiny_fp8_unit.v src/fp8_controller.v src/fp8_elastic_pipeline.v \
    src/fp8_handshake_reg.v src/fp8_pre_execute.v src/fp8_unpack.v \
    src/fp8_execute_comb.v src/fp8_normalize.v src/fp8_round.v
vvp sim/golden.out          # plusargs: +vecfile=..., +maxfail=N, +stop_on_fail
```

## Golden model — [`Golden_model/`](../../Golden_model/)

The reference is a **mathematical specification**: the exact value as a
`Fraction` plus IEEE exceptions, *not* a bit-mirror of the RTL. It was verified
identical to the earlier bit-accurate RTL golden model across all **1,310,720**
cases (256×256 × 4 ops × 5 modes), returning the same `(result, flags, exc)`.

| File | Role |
|------|------|
| `fp8_common.py` | FP8 E4M3 codec (unpack, exact value as a Fraction) |
| `fp8_math.py` | the specification: `A op B` as an exact value + exceptions, rounded to FP8 in the 5 modes |
| `gen_vectors_math.py` | generates the 7-column `vectors.hex` |
| `vectors.hex` | committed golden vectors (~30k evenly-sampled subset; regenerate the full 1.3M set with no args) |

API: `fp8_math(A, B, opcode, rm) -> (result, flags, exc)`. Opcode/rm/flag/
exception encodings are in [ISA Reference](ISA-Reference). Exception handling at
the value level: **INVALID** (Inf−Inf, 0/0, Inf×0, input NaN → quiet propagate),
**DIVZERO** (finite ÷ 0 → ±Inf), **OVERFLOW** (mode-dependent Inf vs saturate),
**UNDERFLOW** (non-zero collapses to zero), **INEXACT** (rounded ≠ exact).

```sh
python3 gen_vectors_math.py            # ADD/SUB/MULT/DIV, 5 modes
python3 gen_vectors_math.py --rne      # NEAREST only
python3 gen_vectors_math.py --quick    # small smoke sample
python3 gen_vectors_math.py --no-div   # exclude DIV
python3 gen_vectors_math.py --out X.hex
```
