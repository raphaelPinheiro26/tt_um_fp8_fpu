![gds](../../workflows/gds/badge.svg) ![docs](../../workflows/docs/badge.svg) ![test](../../workflows/test/badge.svg) ![fpga](../../workflows/fpga/badge.svg)

# FP8 (E4M3) Floating-Point Unit — Tiny Tapeout

An 8-bit IEEE-style floating-point unit (FP8, **E4M3** format) wrapped for
[Tiny Tapeout](https://tinytapeout.com), taped out on the **GF 26b** shuttle
(GlobalFoundries `gf180mcu`). It performs **add, subtract, multiply and divide**
with several IEEE-754 rounding modes, classification flags and exception flags.

The FPU core (`tiny_fp8_unit`) is an **elastic, pipelined** datapath with a wide
handshake interface designed to sit next to a RISC-V core. That interface does
not fit on Tiny Tapeout's pins, so this project adds a thin top-level wrapper,
**`tt_um_fp8_fpu`**, that **streams** operand bytes in and result bytes out over
two independent `valid/ready` handshakes — keeping **several operations in
flight** at once.

> My first Tiny Tapeout chip. 🎉

## Hardening results (GF 26b · gf180mcu)

| Metric            | Value                              |
|-------------------|------------------------------------|
| Process           | GlobalFoundries `gf180mcu` (5 V)   |
| Tiles             | 2×2                                |
| Standard cells    | 3842 (excl. fill/tap)              |
| Core utilisation  | 40.8 %                             |
| Flip-flops        | 440                                |
| Declared clock    | 10 MHz                             |
| DRC / LVS         | clean ✓                            |

The declared 10 MHz is conservative because the divide path is combinational;
the real maximum frequency comes from the STA signoff of the hardening run.

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
[`docs/PROTOCOL.md`](docs/PROTOCOL.md).

```
input  bytes per op : A [, B] [, CTRL]      (B/CTRL skipped via sticky bits)
output bytes per op : result [, flags, exceptions]   (extra two if READ_FULL)
```

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
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) §4.

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
Rounding modes and flag/exception bit positions are defined in
[`src/header_fp8.v`](src/header_fp8.v).

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
[`Golden_model/README.txt`](Golden_model/README.txt).

---

## Repository layout

```
src/                synthesizable RTL (taped out)
  tt_um_fp8_fpu.v     Tiny Tapeout top-level wrapper (streaming valid/ready)
  tiny_fp8_unit.v     FPU core (controller + elastic pipeline)
  fp8_*.v             FPU sub-blocks
  header_fp8.v        shared `defines (format, opcodes, flags)
  config.json         LibreLane / hardening configuration
test/               cocotb test environment (tb.v, test.py, Makefile)
Golden_model/       Python reference model + vector generator + vectors.hex
  vectors.hex         golden vectors (A B opcode rm result flags exc)
docs/PROTOCOL.md    full cycle-by-cycle streaming protocol
docs/info.md        datasheet text
info.yaml           Tiny Tapeout project metadata + pinout
```

This is the canonical Tiny Tapeout layout (sources in `src/`), so
[`info.yaml`](info.yaml) and [`test/Makefile`](test/Makefile) reference it
directly with no extra steps.

---

## License

The Tiny Tapeout wrapper, testbench and documentation are released under the
Apache-2.0 license (`SPDX-License-Identifier: Apache-2.0`).
