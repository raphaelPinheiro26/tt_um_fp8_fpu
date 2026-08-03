# tt_um_fp8_fpu — Pin protocol (streaming)

This document describes, cycle by cycle, how to talk to the `tt_um_fp8_fpu`
wrapper through the Tiny Tapeout pin interface. The wrapper exposes the elastic
core `tiny_fp8_unit` (FP8 E4M3: add/sub/mul/div, 5 rounding modes) as **two
independent `valid`/`ready` channels**, so several operations can be **in flight
at once** (the pipeline stays full).

Everything is synchronous to `clk`. On Tiny Tapeout, `clk`, `rst_n` and the pins
are driven by an external host (the demo board's RP2040, or an ESP32/STM32 on a
custom PCB).

---

## 1. Pin map

| Pin           | Dir | Name        | Function |
|---------------|-----|-------------|----------|
| `ui_in[7:0]`  | in  | DATA_IN     | input byte stream (`A`, then `B`, then `CTRL`) |
| `uo_out[7:0]` | out | DATA_OUT    | output byte stream (result, [flags, exceptions]) |
| `uio_in[0]`   | in  | IN_VALID    | host asserts when `ui_in` holds a valid byte |
| `uio_out[1]`  | out | IN_READY    | core can accept a byte this cycle |
| `uio_out[2]`  | out | OUT_VALID   | `uo_out` holds a valid result byte |
| `uio_in[3]`   | in  | OUT_READY   | host consumed the current `uo_out` byte |
| `uio_in[4]`   | in  | STICKY_CTRL | reuse last `{rm, opcode}`; do NOT send the `CTRL` byte |
| `uio_in[5]`   | in  | STICKY_B    | reuse last `B` operand; do NOT send the `B` byte |
| `uio_in[6]`   | in  | READ_FULL   | 3 output bytes/op (result, flags, exc) instead of 1 |
| `uio_out[7]`  | out | FPU_BUSY    | core busy flag (observability) |
| `clk`         | in  | —           | clock (host controls frequency / stepping) |
| `rst_n`       | in  | —           | reset, active LOW |
| `ena`         | in  | —           | 1 while the design is powered (unused) |

`uio_oe = 8'b1000_0110` → only `uio[7]`, `uio[2]` and `uio[1]` are outputs; the
rest are inputs.

**CTRL byte:** `{ rm = ui_in[7:5], opcode = ui_in[4:0] }`.
Opcodes: `ADD=0, SUB=1, MULT=2, DIV=3`. Rounding modes `rm`: `NEAR=0, ZERO=1,
UP=2, DOWN=3, ODD=4`.

**FP8 E4M3** (see `src/header_fp8.v`): bit 7 = sign, bits 6:3 = exponent
(bias 7), bits 2:0 = mantissa. E.g. `1.0 = 0x38`, `2.0 = 0x40`.

---

## 2. The valid/ready handshake (golden rule)

A transfer happens on the **rising edge of `clk`** where `valid` and `ready` are
**both** 1. This is the classic skid-proof handshake:

- **Input:** the byte on `ui_in` is accepted when `IN_VALID & IN_READY`.
- **Output:** the byte on `uo_out` is consumed when `OUT_VALID & OUT_READY`.

The host must sample `IN_READY`/`OUT_VALID` (chip outputs) and only then decide.
Because the host generates `clk`, it has full control of the pace.

---

## 3. Sequence of one operation

### Input (per operation)
The byte order is **A → B → CTRL**, but `B` and/or `CTRL` are skipped according
to the sticky bits:

```
in_needed = 1 + (STICKY_B ? 0 : 1) + (STICKY_CTRL ? 0 : 1)   // 1..3 bytes
```

- `STICKY_*` both 0 → send 3 bytes: `A`, `B`, `CTRL`.
- `STICKY_CTRL=1` → send 2 bytes: `A`, `B` (reuse previous `rm`/`opcode`).
- `STICKY_B=1, STICKY_CTRL=1` → send 1 byte: `A` (reuse `B` and `rm`/`opcode`).

The **last byte** of each operation triggers the issue **on the same cycle** it
arrives (the core reads the "live" field straight from `ui_in`). That is why the
steady-state initiation interval (II) equals `in_needed` (see §5).

### Output (per result)
```
out_needed = READ_FULL ? 3 : 1
```
- `READ_FULL=0` → 1 byte: result.
- `READ_FULL=1` → 3 bytes: result, then `{1'b0, flags[6:0]}`, then
  `{3'b0, exceptions[4:0]}`.

Results come out in the **same order** the operations were issued.

---

## 4. Sticky modes — how to initialise

The `B` and `{rm, opcode}` registers hold the last value sent. To use sticky:

1. Send **one full operation** with `STICKY_B=0` and `STICKY_CTRL=0` (this loads
   `B` and `CTRL` into the holding registers).
2. Raise the desired sticky bits.
3. Subsequent operations omit the sticky bytes and reuse the stored values.

**Constraint:** keep `STICKY_*` and `READ_FULL` **stable across the bytes of a
single operation**; only change them between operations (at an op boundary).

Use cases:
- `STICKY_CTRL` — benchmarking a single operation type (the normal case when
  measuring).
- `STICKY_B` — "A op constant" (e.g. scale a stream by a fixed factor).

---

## 5. Throughput and latency (what to measure)

With the host always feeding (`IN_VALID=1` while `IN_READY=1`) and always
draining (`OUT_READY=1`), the steady-state **initiation interval** is:

```
II  ≈ max(in_needed, out_needed)   cycles/op
```

Validated in the cycle-accurate protocol model:

| Mode                                 | in/out bytes | measured II |
|--------------------------------------|--------------|-------------|
| full (no sticky, READ_FULL=1)        | 3 / 3        | 3.0         |
| STICKY_CTRL, result-only             | 2 / 1        | 2.0         |
| STICKY_CTRL + STICKY_B, result-only  | 1 / 1        | 1.0         |

**Latency** = cycles from the issue of one operation until `OUT_VALID` rises for
its result (pipeline depth). Measure it by sending 1 operation and counting
`clk` edges until `OUT_VALID`.

**Pipeline speed-up** = same board, two host policies:
- *blocking* (insert-and-wait): send op, wait for the result, send the next
  → ~ `N × latency` cycles for N ops.
- *streaming*: feed continuously → ~ `N × II + latency` cycles.
- speed-up ≈ `latency / II`.

**ops/second** on silicon = `fmax / II`, where `fmax` comes from static timing
analysis (STA / LibreLane), not from the host measurement.

### Counting cycles without extra hardware
The host **generates** `clk` (stepping or by timer), so it just counts the edges
it produced — an exact count, with no on-chip counter. On the TT board's
MicroPython firmware you can advance the clock in software and count.

---

## 6. Timing examples

### Full operation, reading only the result (`STICKY_CTRL=1`, `READ_FULL=0`)
Pre-condition: a full operation has already loaded `rm`/`opcode`.

```
cycle │ ui_in │ IN_VALID IN_READY │ uo_out  OUT_VALID OUT_READY │ note
------┼-------┼-------------------┼-----------------------------┼-----------------
  0   │  A0   │    1       1      │   --        0        1      │ accept A0
  1   │  B0   │    1       1      │   --        0        1      │ B0 = last → issue op0
  2   │  A1   │    1       1      │   --        0        1      │ accept A1
  3   │  B1   │    1       1      │   --        0        1      │ issue op1
 ...  │       │                   │  res0       1        1      │ result0 comes out (after latency)
```
Steady state: 2 input bytes per op (II=2), results draining 1/op in parallel on
the output bus.

### Best case (`STICKY_CTRL=1`, `STICKY_B=1`, `READ_FULL=0`)
1 byte (`A`) per operation, 1 byte (result) per result → **II = 1 op/cycle**
when the pipeline is full.

---

## 7. Reset and design selection (Tiny Tapeout)

1. Select the design in the TT multiplexer (pulse `ctrl_sel_rst_n` and
   `ctrl_sel_inc` until the project's address) — handled by the TT API/firmware.
2. Pulse `rst_n` LOW for a few cycles, then release.
3. After reset: `in_count=0`, `out_busy=0`. Keep `STICKY_*=0` on the first
   operation to initialise `B`/`CTRL`.

---

## 8. Summary of internal tie-offs (standalone on chip)

| Core signal | Value in the wrapper |
|-------------|----------------------|
| `issue_rd`  | `0` (no register file on chip) |
| `wb_rd`     | ignored |
| `flush`     | `0` (never) |
| `wb_ready`  | generated by the output serializer (real back-pressure) |

`wb_ready` dropping (slow host draining) propagates back-pressure into the
pipeline and eventually lowers `IN_READY` — end-to-end elastic flow control.
