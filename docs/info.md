<!---

This file is used by Tiny Tapeout to generate the project datasheet page.
Write the documentation for your project here.

-->

## How it works

This project tapes out an **8-bit floating-point unit (FPU)** in the
**FP8 E4M3** format: 1 sign bit, 4 exponent bits (bias 7) and 3 mantissa bits.
The core, `tiny_fp8_unit`, performs **add, subtract, multiply and divide** with
five IEEE-754 rounding modes and produces IEEE-style classification flags and
exception flags. It is a fully **pipelined, elastic datapath** (4 register
stages separated by valid/ready skid buffers) that can hold several operations
in flight at once.

The core's native interface is far wider than Tiny Tapeout's pin budget (it
needs ~32 input bits and ~28 output bits). To fit, the top-level wrapper
`tt_um_fp8_fpu` **time-multiplexes** everything onto a single 8-bit data bus and
exposes the core as a **byte stream with two independent `valid`/`ready`
handshakes** — one for input, one for output. Because the two handshakes are
independent, the host can keep feeding new operands while draining previous
results, keeping the pipeline full.

### Operation

Each operation is a short sequence of input bytes and output bytes:

```
input  bytes per op :  A  ->  B  ->  CTRL      (B and/or CTRL may be skipped, see sticky)
output bytes per op :  RESULT [ -> FLAGS -> EXCEPTIONS ]   (last two only if READ_FULL)
```

- `CTRL` byte = `{ rm = ui_in[7:5], opcode = ui_in[4:0] }`.
- Opcodes: `ADD=0, SUB=1, MULT=2, DIV=3`.
- Rounding modes `rm`: `NEAREST=0, ZERO=1, UP=2, DOWN=3, ODD=4`.
- FP8 E4M3 encoding: bit 7 = sign, bits 6:3 = exponent (bias 7), bits 2:0 =
  mantissa. For example `1.0 = 0x38`, `2.0 = 0x40`.

A transfer happens on the rising `clk` edge where **both** `valid` and `ready`
are high. Results come out **in the same order** the operations went in.

Two "sticky" configuration bits let the host avoid re-sending unchanged fields:
`STICKY_B` reuses the last `B` operand, and `STICKY_CTRL` reuses the last
`{rm, opcode}`. `READ_FULL` selects whether the chip returns just the result
byte (1 byte/op) or the result plus flags and exceptions (3 bytes/op). See
[`../docs/PROTOCOL.md`](PROTOCOL.md) for the full cycle-by-cycle protocol.

### Pinout

**Inputs**
- `ui_in[7:0]` — `DATA_IN`: input byte stream (`A`, then `B`, then `CTRL`).
- `uio_in[0]` — `IN_VALID`: host asserts when `ui_in` holds a valid byte.
- `uio_in[3]` — `OUT_READY`: host has consumed the current `DATA_OUT` byte.
- `uio_in[4]` — `STICKY_CTRL`: reuse last `{rm, opcode}`, do not send `CTRL`.
- `uio_in[5]` — `STICKY_B`: reuse last `B` operand, do not send `B`.
- `uio_in[6]` — `READ_FULL`: return 3 bytes/op (result, flags, exceptions).

**Outputs**
- `uo_out[7:0]` — `DATA_OUT`: output byte stream (result, [flags, exceptions]).
- `uio_out[1]` — `IN_READY`: core can accept an input byte this cycle.
- `uio_out[2]` — `OUT_VALID`: `uo_out` holds a valid result byte.
- `uio_out[7]` — `FPU_BUSY`: core has work in flight (observability).

The bidirectional enable is `uio_oe = 8'b1000_0110`, i.e. only `uio[7]`,
`uio[2]` and `uio[1]` are outputs; the rest are inputs.

## How to test

After reset the bus is idle. To compute `A op B` in the simplest "full" mode
(`STICKY_*` low, `READ_FULL = 1`):

1. Drive `A` on `ui_in`, assert `IN_VALID`, and wait for the cycle where
   `IN_READY` is also high — that byte is now accepted.
2. Repeat for `B`, then for the `CTRL` byte `{rm, opcode}`. The `CTRL` byte
   issues the operation.
3. Assert `OUT_READY` and read `DATA_OUT` on each cycle where `OUT_VALID` is
   high: first the **result**, then **flags**, then **exceptions**.

Example — `1.0 + 1.0`: FP8 `1.0 = 0x38`, `ADD` opcode `= 0x00`, `rm = 0`. Send
`0x38`, `0x38`, `0x00`; the result byte is `0x40` (= 2.0).

The cocotb test in [`../test/test.py`](../test/test.py) drives the pins exactly
like a silicon host and self-checks every result, flag and exception against the
golden reference in `Golden_model/vectors.hex`, including a back-pressure stress
test and a sticky-mode test.

## External hardware

None required. Any host that can drive the 8 data inputs and the handshake pins
and read the 8 data outputs — a microcontroller (the Tiny Tapeout demo board's
RP2040, an ESP32/STM32, …), an FPGA, or a logic analyser with a pattern
generator — can operate the FPU. Because the host also supplies `clk`, it has
full control of the timing and can single-step the interface.
