[![gds](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/gds.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/gds.yaml)
[![docs](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/docs.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/docs.yaml)
[![test](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/test.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/test.yaml)
[![fpga](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/fpga.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/fpga.yaml)

# FP8 (E4M3) Floating-Point Unit — Tiny Tapeout

An 8-bit IEEE-style floating-point unit (FP8, **E4M3** format) wrapped for
[Tiny Tapeout](https://tinytapeout.com), targeting the **SKY 26c** shuttle
(ChipFoundry `sky130A`). It is a **12-operation** IEEE-754-style unit with
several rounding modes, classification flags and exception flags. Divide and
square-root share a single **iterative, variable-latency** unit
(`fp8_div_iter`, 1 digit/cycle); everything else is single-cycle in the pipeline.

**Opcodes** (CTRL byte `opcode = ui_in[4:0]`):

| op | name | operands | `DATA_OUT` (result byte) |
|----|------|----------|--------------------------|
| 0 | ADD | A,B | FP8 |
| 1 | SUB | A,B | FP8 |
| 2 | MULT | A,B | FP8 |
| 3 | DIV | A,B | FP8 (iterative) |
| 4 | SQRT | A | FP8 (iterative) |
| 5 | MIN | A,B | FP8 (IEEE-2019, NaN propagates) |
| 6 | MAX | A,B | FP8 (IEEE-2019, NaN propagates) |
| 7 | ABS | A | FP8 |
| 8 | CLASSIFY | A | class enum `result[3:0]` = 0..9 (sNaN,qNaN,−inf,−normal,−sub,−0,+0,+sub,+normal,+inf) |
| 9 | COMPARE | A,B | one-hot `result[3:0]` = {unordered, gt, eq, lt} |
| 10 | SCALB | A, n=B | FP8 = A·2ⁿ (n is B as signed int8) |
| 11 | ROUNDINT | A | FP8 = round-to-integral (rm selects the mode) |
| 12 | NEG | A | FP8 = negate(A): A with the sign bit flipped |
| 13 | COPYSIGN | A,B | FP8 = copySign(A,B): magnitude/payload of A, sign of B |

Unary ops (SQRT, ABS, CLASSIFY, ROUNDINT, NEG) take A and ignore B. NEG and
COPYSIGN are pure sign operations (bit-level, no exceptions, and they do not
signal on NaN). The whole
datapath is **exhaustively verified** against a Fraction-exact IEEE reference
model (`Golden_model/fp8_math.py`).

The FPU core (`tiny_fp8_unit`) is an **elastic, pipelined** datapath with a wide
handshake interface designed to sit next to a RISC-V core. That interface does
not fit on Tiny Tapeout's pins, so this project adds a thin top-level wrapper,
**`tt_um_fp8_fpu`**, that **streams** operand bytes in and result bytes out over
two independent `valid/ready` handshakes — keeping **several operations in
flight** at once.

> My first Tiny Tapeout chip. 🎉

## Target shuttle: SKY 26c (sky130A), 1×2

This project is being migrated to the **SKY 26c** shuttle (ChipFoundry
`sky130A`) and shrunk from **2×2 to 1×2** tiles after a targeted area-reduction
pass (see below). Latest sky130 hardening run (LibreLane, `CLOCK_PERIOD=100 ns`):

| Metric | Value |
|--------|-------|
| Process / PDK | ChipFoundry `sky130A` (1.8 V) |
| Tiles | 1×2 |
| Logic cells (excl. fill/tap) | **2 396** |
| Total cells (incl. fill/tap) | 5 470 |
| Flip-flops (`dfrtp`) | **227** (hardened netlist; ≈161 at RTL synth, was 440) |
| Multiplexers (`mux2`/`mux4`) | 257 |
| Core utilisation | **72.4 %** |
| Wire length | **89 432 µm** |
| Declared clock | 10 MHz |
| Pipeline latency | 3 stages (was 4) |
| **TT precheck** | **15 / 15 ✅** (Magic DRC · KLayout FEOL/BEOL/offgrid/pin/zero-area · pin/boundary/power/layer/cell-name/nwell · analog-pin · Verilog-syntax) |
| **Gate-level tests** | **6 / 6 passed** |

Characterization from the earlier clock-sweep run *(predates the netlist above;
re-extract to refresh)*:

| Metric | Value |
|--------|-------|
| Cell / die area | 34 255 / 36 347 µm² |
| Setup / hold slack | +47.06 ns / +0.12 ns (meets @10 MHz) |
| Fmax (clock sweep) | **as-is ≈ 24 MHz; ceiling ≈ 40 MHz** (critical-path floor ≈ 24 ns) |
| Total power | ≈ 2.3 mW *(default activity — see note)* |
| Max slew / cap violations | 742 / 0 *(clock is very relaxed)* |
| DRC / LVS | run and **clean** in the TT precheck (see above) |

The full standard-cell breakdown of the latest run: 648 combinational, 257
multiplexers, 227 NOR/XNOR, 227 flip-flops, 195 OR/XOR, 164 NAND, 148 clock, 131
AND, 81 buffer, 59 inverter, 30 diode, plus 229 misc — **2 396 cells** total
(excluding 2 618 fill and 456 tap cells).

**Reading the numbers.** At the declared 10 MHz the design meets timing with huge
margin (+47 ns setup slack). A **clock sweep** (`flow/sweep_clock.py`) tells the
real story: at a relaxed target the tool leaves the critical path long
(~52.9 ns → the naive 18.9 MHz), but under pressure it squeezes the path down to
a **floor of ≈ 24 ns** — so **Fmax tops out around 40 MHz**, roughly 2× the naive
estimate. That floor is the **combinational C0 stage** (unpack → pre-execute →
execute → normalize, incl. the barrel shifter): buffering cannot cross it, so
**pipelining C0** is the lever for higher Fmax. (At loose targets the sweep
misses closure by only ~1 ns, which looks like a hold-fixing/margin artifact
rather than the datapath.) Power scales ~linearly with frequency, ~0.28 mW/MHz
(5.7 mW @25 MHz → 20 mW @77 MHz). The 742 max-slew violations are a
signal-integrity/quality item (high-fanout nets unbuffered under the relaxed
clock), not a timing failure.

> **Power caveat.** `power__total` (≈2.3 mW) comes from OpenSTA with **default
> switching activity**, so the dynamic part (internal + switching) is an
> estimate, not a measurement. Leakage (~34 nW) is workload-independent and
> trustworthy. For realistic dynamic power on a specific workload (e.g. a stream
> of DIVs vs ADDs), feed a VCD/SAIF from a gate-level sim into STA — see
> [`flow/README.md`](flow/README.md).

**Sizing rationale.** The prior **GF 26b** run (GlobalFoundries `gf180mcu`,
5 V) hardened at 2×2 with 3842 standard cells, 440 flip-flops and only
**40.8 % core utilisation** — i.e. the design used roughly 1.6 tiles of logic
in 4 tiles of area. A dedicated area-reduction pass then cut the design's
flip-flops by roughly half (**440 → ≈161** at yosys `synth`; the hardened
sky130 netlist places **227** `dfrtp`, the extra coming from tech-mapping and
the rd-FIFO realised as registers) and its generic-gate count by **26 %**,
which — combined with the smaller sky130 HD cells — brings the design down to a
**1×2** tile footprint.

**What changed (all provably behaviour-preserving).** The FP8 numerical result,
flags and exceptions are **bit-identical** to the previous design: the entire
combinational datapath (unpack → pre-execute → execute → normalize → round) was
proven equivalent to the original for **all 2²⁴ input combinations** by a yosys
SAT miter, and the pipeline passes the full 30 482-vector golden regression plus
a randomised back-pressure stream test.

1. **Depth-1 elastic pipeline registers.** `fp8_handshake_reg` was a 2-deep skid
   buffer (`2·W+2` flops per stage). It is now a single-item elastic register
   (`W+1` flops) with `ready_out = ready_in | ~valid_out`, which preserves the
   valid/ready contract with **no data loss or reordering** under back-pressure.
   This alone removed ~200 flip-flops.
2. **Narrower combinational divider.** The divide keeps `NRM_QDIV` fractional
   quotient bits; E4M3 only needs guard/round plus the remainder sticky, so
   `NRM_QDIV` dropped from **10 → 5**, shrinking the combinational divide array
   (proven bit-exact by SAT).
3. **Fused execute+normalize stage.** Normalisation moved into the same
   combinational stage as execute, so the first pipeline register now stores the
   16-bit normalised ruler instead of the three raw operation buses
   (acc/quot/prod + exponents). Pipeline depth went from 4 to 3.
4. **Shared normaliser + smaller rd FIFO.** The add/sub and divide paths now
   share one priority-encoder + barrel-shifter in `fp8_normalize`, and
   `RD_FIFO_DEPTH` was reduced from 8 to 4 (the on-chip wrapper does not use the
   `rd` field, so this is essentially free).

---

## The pin problem

Tiny Tapeout gives every project a fixed pin budget:

| Group        | Width | Direction                                  |
|--------------|-------|--------------------------------------------|
| `ui_in`      | 8     | dedicated inputs                           |
| `uo_out`     | 8     | dedicated outputs                          |
| `uio`        | 8     | bidirectional (each pin input *or* output) |
| `clk`, `rst_n`, `ena` | — | clock, active-low reset, power-enable |

That is **24 general-purpose I/O + clk + rst** = the 26 usable pins.

The FPU core needs **32 input bits** (`issue_valid`, `A[8]`, `B[8]`,
`opcode[5]`, `rm[3]`, `rd[5]`, `wb_ready`, `flush`) and **28 output bits**
(`result[8]`, `flags[7]`, `exceptions[5]`, `rd[5]`, plus status). It cannot be
wired to the pins directly.

## The solution: a streaming valid/ready wrapper

The wrapper time-multiplexes everything onto a single 8-bit data bus, but unlike
a fixed phase FSM it decouples input from output with **two independent
`valid/ready` handshakes**. The host (the board's RP2040, or an ESP32/STM32 on a
custom PCB) keeps **feeding new operand bytes while draining results**, so
multiple operations stay in the pipeline and the steady-state initiation
interval (II, cycles/op) drops toward the number of bytes per operation — as low
as **1** in the best case.

A transfer happens on the rising edge of `clk` where `valid` **and** `ready` are
both high. The full cycle-by-cycle protocol is in
[`docs/wiki/Pin-Protocol.md`](docs/wiki/Pin-Protocol.md).

```
input  bytes per op : A [, B] [, CTRL]      (B/CTRL skipped via sticky bits)
output bytes per op : result [, flags, exceptions]   (extra two if READ_FULL)
```

---

## Inside the core (architecture)

The wrapper is deliberately thin: all it does is (de)serialise bytes and drive
the two handshakes. The arithmetic lives in `tiny_fp8_unit`, which is a
**controller** in front of a **4-stage elastic pipeline**:

```
   tt_um_fp8_fpu (streaming byte I/O)
   └── tiny_fp8_unit
       ├── fp8_controller ....... issue/writeback handshakes + rd FIFO
       └── fp8_elastic_pipeline . 4 stages, each a valid/ready skid buffer
             R0→R1  unpack + pre_execute + execute   (combinational, "raw")
             R1→R2  normalize                          (raw → 16-bit ruler)
             R2→R3  round                              (ruler → final FP8)
             R3→R4  special/normal mux + output
```

Every operation — normal, subnormal, NaN, Inf, overflow — takes the **same,
fixed number of stages**, so results always leave in the order they were issued.
Each stage is separated by `fp8_handshake_reg`, a two-slot elastic skid buffer;
when the consumer stalls, back-pressure ripples upstream and eventually lowers
`IN_READY`, with **no data ever lost or reordered**.

The combinational blocks in `src/` each own one job:

| Block                  | Job                                                        |
|------------------------|-----------------------------------------------------------|
| `fp8_unpack`           | split a byte into sign/exp/mant and classify it (flags)   |
| `fp8_pre_execute`      | resolve special cases (NaN / Inf / zero) up front         |
| `fp8_execute_comb`     | the arithmetic: pre-normalise operands, then add/sub/mul/div into a wide, sticky-preserving result |
| `fp8_normalize`        | shift the raw result onto a 16-bit ruler (hidden bit at the top) |
| `fp8_round`            | choose normal vs subnormal, round in the selected mode, detect overflow/underflow/inexact |

## Pin map

### Inputs
| Pin          | Name        | Meaning                                              |
|--------------|-------------|------------------------------------------------------|
| `ui_in[7:0]` | `DATA_IN`   | input byte stream: A, then B, then CTRL              |
| `uio_in[0]`  | `IN_VALID`  | host asserts when `ui_in` holds a valid byte         |
| `uio_in[3]`  | `OUT_READY` | host consumed the current `uo_out` byte              |
| `uio_in[4]`  | `STICKY_CTRL` | reuse last `{rm,opcode}`; do **not** send CTRL byte |
| `uio_in[5]`  | `STICKY_B`  | reuse last B operand; do **not** send B byte         |
| `uio_in[6]`  | `READ_FULL` | output 3 bytes/op (result, flags, exc) instead of 1  |
| `uio_in[2:1,7]` | —        | unused (inputs)                                      |

The CTRL byte is `{ rm = ui_in[7:5], opcode = ui_in[4:0] }`.

### Outputs
| Pin          | Name        | Meaning                                              |
|--------------|-------------|------------------------------------------------------|
| `uo_out[7:0]`| `DATA_OUT`  | output byte stream: result [, flags, exceptions]     |
| `uio_out[1]` | `IN_READY`  | core can accept an input byte this cycle             |
| `uio_out[2]` | `OUT_VALID` | `uo_out` holds a valid result byte                   |
| `uio_out[7]` | `FPU_BUSY`  | core busy flag (observability)                       |
| `uio_out[6:3,0]` | —       | driven to 0                                          |

`uio_oe = 8'b1000_0110` — only `uio[7]`, `uio[2]` and `uio[1]` are outputs; the
rest are inputs.

### Sticky / READ_FULL — bytes per operation
```
in_needed  = 1 + (STICKY_B ? 0 : 1) + (STICKY_CTRL ? 0 : 1)   // 1..3
out_needed = READ_FULL ? 3 : 1
```
To use the sticky reuse, send **one full operation first** (both sticky bits
low) to load the B / CTRL holding registers, then raise the sticky bits and keep
them stable across the bytes of each later operation. See
[`docs/wiki/Pin-Protocol.md`](docs/wiki/Pin-Protocol.md) §4.

## FP8 E4M3 format

```
 bit  7   6 5 4 3   2 1 0
     [S] [ exp(4) ] [mant(3)]      bias = 7
```

| Value | Encoding   | Hex  |
|-------|------------|------|
| 1.0   | 0 0111 000 | 0x38 |
| 2.0   | 0 1000 000 | 0x40 |
| 3.0   | 0 1000 100 | 0x44 |
| 6.0   | 0 1001 100 | 0x4C |

Opcodes: `ADD=00000`, `SUB=00001`, `MUL=00010`, `DIV=00011`.
The full opcode, rounding-mode, flag and exception tables are in
[`docs/wiki/ISA-Reference.md`](docs/wiki/ISA-Reference.md) (from
[`src/header_fp8.v`](src/header_fp8.v)).

## How to drive operations (full mode)

With `STICKY_*` low and `READ_FULL=1` each op is 3 bytes in, 3 bytes out.

Input side (host → chip), one transfer per cycle where `IN_VALID & IN_READY`:

1. Drive **A** on `ui_in`, raise `IN_VALID`. When `IN_READY` is high, the byte
   is taken on the next clock edge.
2. Drive **B**, then the **CTRL** byte the same way. The CTRL byte issues the
   operation in the same cycle it is accepted.
3. You may start the next op's **A** immediately — no need to wait for results.

Output side (chip → host), one transfer per cycle where `OUT_VALID & OUT_READY`:

4. When `OUT_VALID` is high, read `uo_out` and pulse `OUT_READY` to consume it.
   The bytes arrive in order: **result**, then `{0,flags[6:0]}`, then
   `{0,exceptions[4:0]}` (the last two only when `READ_FULL=1`). Results come
   out **in the same order** the operations went in.

If the host stalls the output (`OUT_READY` low), the result FIFO fills, the
pipeline back-pressures, and `IN_READY` drops — end-to-end elastic flow control,
so nothing is ever lost.

Worked example — `1.0 + 1.0`: stream `0x38` (A), `0x38` (B), `0x00` (CTRL:
rm=0/near, op=0/ADD); read `0x40` (= 2.0) when `OUT_VALID` rises.

---

## Testing

Tests use [cocotb](https://www.cocotb.org/) and live in [`test/`](test/).

> For a single end-to-end WSL2 setup covering simulation, the `verification/`
> tracks (formal · UVM · DFT), LibreLane hardening and **metrics extraction for
> characterisation**, see [`docs/wiki/Getting-Started.md`](docs/wiki/Getting-Started.md)
> and the tooling in [`flow/`](flow/).

```bash
# one-time setup (Debian/Ubuntu). On Windows, the OSS CAD Suite ships all of
# these: https://github.com/YosysHQ/oss-cad-suite-build/releases
sudo apt install iverilog make
pip3 install cocotb pytest

# run the RTL tests
cd test
make
```

`make` builds the design and runs [`test/test.py`](test/test.py), which drives
the streaming pins exactly like the silicon host:

- `test_reset_and_idle` — after reset `OUT_VALID` is low and `uio_oe` is
  `0b1000_0110`.
- `test_add_smoke` — a readable `1.0 + 1.0 == 2.0` check.
- `test_vectors_streaming` — **self-checking**: streams a sample of the golden
  vectors in [`Golden_model/vectors.hex`](Golden_model/vectors.hex) at full
  throughput (no bubbles, no back-pressure) and compares result / flags /
  exceptions **in order**. Defaults to 1500 vectors sampled evenly across all
  four ops and five rounding modes.
- `test_vectors_backpressure` — the same vectors with **random input bubbles and
  output back-pressure**, exercising the `IN_READY` / issue stall path and the
  in-order scoreboard (catches any loss, duplication or reordering).
- `test_sticky_ctrl_result_only` — exercises `STICKY_CTRL` + `READ_FULL=0`
  (2 bytes in / 1 byte out, II ≈ 2).

Knobs (environment variables):

```bash
FP8_NVEC=5000 make    # streaming test: check 5000 vectors (0 = all in the file)
FP8_NBP=1000 make     # back-pressure test: 1000 vectors
FP8_SEED=7 make       # change the back-pressure RNG seed
```

A waveform is written to `test/tb.fst` (open with GTKWave or Surfer).
Gate-level tests run with `make GATES=yes` after hardening produces a netlist.
The Tiny Tapeout GitHub Actions also run these tests automatically on every push.

The committed [`Golden_model/vectors.hex`](Golden_model/vectors.hex) holds ~30k
vectors sampled evenly across all four ops and five rounding modes — enough to
exercise the corners while keeping the repo small. The full exhaustive set
(1,310,720 vectors) is regenerated from the Python reference model with
`python3 Golden_model/gen_vectors_math.py`; see
[`Golden_model/README.md`](Golden_model/README.md).

### Block-level tests (`sim/cocotb/`)

Beyond the top-level suite, each building block has its own cocotb testbench in
[`sim/cocotb/`](sim/cocotb/) (Python ports of the legacy Verilog testbenches):

- **`handshake/`** — pushes a counter through the elastic skid buffer with random
  bubbles / back-pressure and asserts the stream stays byte-exact and in order.
- **`pipeline/`** — directed NaN/Inf/zero/subnormal cases plus a golden-vector
  replay through the 4-stage datapath, at full throughput and under back-pressure.
- **`unit/`** — the same golden replay through `controller + pipeline`, also
  checking the `rd` tag returns in order.
- **`controller/`** — drives the issue interface against a Python model of the
  pipeline; checks in-order writeback, the `rd` FIFO full/stall behaviour and `flush`.

```bash
cd sim/cocotb/pipeline && make      # (also: unit, handshake, controller)
```

### Legacy Verilog testbenches (`sim/`)

The original stand-alone Verilog testbenches are kept in [`sim/`](sim/) for
reference and quick local debugging (they are **not** part of the Tiny Tapeout
flow). `sim/README.md` lists them and how to run them with Icarus Verilog;
`tb_fp8_golden.v` replays the entire `vectors.hex` against the pipeline.

### Verification status

The RTL has been checked at every level: the pipeline passes the **full
exhaustive set of 1,310,720 golden vectors** (256×256 operands × 4 ops ×
5 rounding modes) with zero mismatches, and the top-level streaming wrapper
passes the cocotb suite (full-throughput replay, random back-pressure, and
sticky mode). The Python reference model (`Golden_model/fp8_math.py`) is itself
a value-exact IEEE-like specification, verified identical to the earlier
bit-accurate RTL golden model across all 1,310,720 cases.

---

## Verification methodology track — UVM · Formal · DFT

Beyond sign-off, [`verification/`](verification/) turns this design into a
hands-on **portfolio and study track** for three pillars of modern silicon
verification, all with open-source tooling:

- **[Formal](verification/formal/)** (Yosys + SymbiYosys) — proves the elastic
  `valid/ready` pipeline is lossless, order-preserving and non-corrupting under
  arbitrary back-pressure, and that the divider stalls the chain in order. The
  centrepiece is a k-induction proof of the depth-1 buffer `fp8_handshake_reg`.
- **[UVM](verification/uvm/)** (pyuvm + cocotb) — a layered, constrained-random
  testbench for the streaming top-level (sequence → driver → monitor →
  scoreboard), self-checked against `Golden_model/fp8_math.py`, with a
  SystemVerilog-UVM reference mirror for reading both dialects side by side.
- **[DFT](verification/dft/)** (Yosys) — scan-chain concepts, a flop inventory
  of the taped-out netlist, and a worked scan-insertion example.

Each track has its own README with the concepts, how they map to this RTL, exact
run commands, and exercises. Start at [`verification/README.md`](verification/README.md).

---

## Repository layout

```
src/                synthesizable RTL (taped out)
  tt_um_fp8_fpu.v     Tiny Tapeout top-level wrapper (streaming valid/ready)
  tiny_fp8_unit.v     FPU core (controller + elastic pipeline)
  fp8_*.v             FPU sub-blocks
  header_fp8.v        shared `defines (format, opcodes, flags)
  config.json         LibreLane / hardening configuration
test/               cocotb test environment run by Tiny Tapeout (tb.v, test.py, Makefile)
sim/                legacy stand-alone Verilog testbenches (reference / local debug)
  cocotb/             block-level cocotb testbenches (pipeline, unit, controller, handshake)
Golden_model/       Python reference model + vector generator + vectors.hex
  vectors.hex         golden vectors (A B opcode rm result flags exc)
verification/       methodology study track (portfolio, not taped out)
  formal/             SymbiYosys handshake/pipeline proofs (valid/ready contract)
  uvm/                pyuvm testbench + SystemVerilog-UVM reference mirror
  dft/                Design-for-Test: scan concepts, Yosys flop inventory, scan example
docs/               all documentation (English)
  wiki/               single-source GitHub Wiki pages (guided docs)
  info.md             Tiny Tapeout datasheet text (fixed path required by TT)
info.yaml           Tiny Tapeout project metadata + pinout
```

This is the canonical Tiny Tapeout layout (sources in `src/`), so
[`info.yaml`](info.yaml) and [`test/Makefile`](test/Makefile) reference it
directly with no extra steps.

---

## License

The Tiny Tapeout wrapper, testbench and documentation are released under the
Apache-2.0 license (`SPDX-License-Identifier: Apache-2.0`).
