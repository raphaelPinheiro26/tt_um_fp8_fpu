# Pin Protocol (streaming)

Cycle-by-cycle guide to talking to the `tt_um_fp8_fpu` wrapper over the Tiny
Tapeout pins. The core is exposed as **two independent `valid`/`ready` channels**
(one input, one output), so several operations can be **in flight at once**.
Everything is synchronous to `clk`, driven by an external host (the demo board's
RP2040, or an ESP32/STM32 on a custom PCB).

## 1. Pin map

| Pin | Dir | Name | Function |
|-----|-----|------|----------|
| `ui_in[7:0]` | in | DATA_IN | input byte stream (`A`, then `B`, then `CTRL`) |
| `uo_out[7:0]` | out | DATA_OUT | output byte stream (result, [flags, exceptions]) |
| `uio_in[0]` | in | IN_VALID | host asserts when `ui_in` holds a valid byte |
| `uio_out[1]` | out | IN_READY | core can accept a byte this cycle |
| `uio_out[2]` | out | OUT_VALID | `uo_out` holds a valid result byte |
| `uio_in[3]` | in | OUT_READY | host consumed the current `uo_out` byte |
| `uio_in[4]` | in | STICKY_CTRL | reuse last `{rm, opcode}`; don't send `CTRL` |
| `uio_in[5]` | in | STICKY_B | reuse last `B`; don't send `B` |
| `uio_in[6]` | in | READ_FULL | 3 output bytes/op (result, flags, exc) instead of 1 |
| `uio_out[7]` | out | FPU_BUSY | core busy flag (observability) |
| `clk` | in | — | clock (host controls frequency / stepping) |
| `rst_n` | in | — | reset, active LOW |
| `ena` | in | — | 1 while powered (unused) |

`uio_oe = 8'b1000_0110` → only `uio[7]`, `uio[2]`, `uio[1]` are outputs; the rest
are inputs. **CTRL byte** = `{ rm = ui_in[7:5], opcode = ui_in[4:0] }`. Opcode,
rounding-mode, flag and exception encodings: [ISA Reference](ISA-Reference).

## 2. The valid/ready handshake (golden rule)

A transfer happens on the **rising edge of `clk`** where `valid` **and** `ready`
are both 1:

- **Input:** the byte on `ui_in` is accepted when `IN_VALID & IN_READY`.
- **Output:** the byte on `uo_out` is consumed when `OUT_VALID & OUT_READY`.

The host samples `IN_READY`/`OUT_VALID` (chip outputs) and only then decides.
Because the host generates `clk`, it fully controls the pace.

## 3. Sequence of one operation

The input byte order is **A → B → CTRL**, with `B` and/or `CTRL` skipped per the
sticky bits:

```
in_needed  = 1 + (STICKY_B ? 0 : 1) + (STICKY_CTRL ? 0 : 1)   // 1..3 bytes
out_needed = READ_FULL ? 3 : 1
```

- `STICKY_*` both 0 → 3 input bytes: `A`, `B`, `CTRL`.
- `STICKY_CTRL=1` → 2 bytes: `A`, `B` (reuse previous `rm`/`opcode`).
- `STICKY_B=1, STICKY_CTRL=1` → 1 byte: `A`.
- `READ_FULL=0` → 1 output byte (result); `READ_FULL=1` → 3 bytes: result, then
  `{1'b0, flags[6:0]}`, then `{3'b0, exceptions[4:0]}`.

The **last byte** of each operation triggers the issue on the same cycle it
arrives (the core reads the "live" field straight from `ui_in`) — that is why the
steady-state initiation interval equals `in_needed`. Results come out in the
**same order** the operations were issued.

## 4. Sticky modes — how to initialise

The `B` and `{rm, opcode}` registers hold the last value sent. To use sticky:

1. Send **one full operation** with `STICKY_B=0`, `STICKY_CTRL=0` (loads `B` and
   `CTRL` into the holding registers).
2. Raise the desired sticky bits.
3. Subsequent operations omit the sticky bytes and reuse the stored values.

**Constraint:** keep `STICKY_*` and `READ_FULL` **stable across the bytes of a
single operation**; only change them at an operation boundary. Use cases:
`STICKY_CTRL` for benchmarking one op type; `STICKY_B` for "A op constant".

## 5. Throughput and latency

With the host always feeding and draining, the steady-state **initiation
interval** is `II ≈ max(in_needed, out_needed)` cycles/op. Validated in the
cycle-accurate model:

| Mode | in/out bytes | measured II |
|------|--------------|-------------|
| full (no sticky, READ_FULL=1) | 3 / 3 | 3.0 |
| STICKY_CTRL, result-only | 2 / 1 | 2.0 |
| STICKY_CTRL + STICKY_B, result-only | 1 / 1 | 1.0 |

**Latency** = cycles from issue until `OUT_VALID` rises for that result (pipeline
depth). **Pipeline speed-up** ≈ `latency / II` (streaming vs insert-and-wait).
`ops/second` on silicon = `fmax / II`, where `fmax` comes from STA (LibreLane),
not the host. The host generates `clk`, so it counts edges exactly — no on-chip
counter needed (the TT board's MicroPython firmware can step the clock in
software).

## 6. Timing examples

**Full op, reading only the result (`STICKY_CTRL=1`, `READ_FULL=0`)** —
pre-condition: a full op already loaded `rm`/`opcode`.

```
cycle │ ui_in │ IN_VALID IN_READY │ uo_out  OUT_VALID OUT_READY │ note
------┼-------┼-------------------┼-----------------------------┼-----------------
  0   │  A0   │    1       1      │   --        0        1      │ accept A0
  1   │  B0   │    1       1      │   --        0        1      │ B0 = last → issue op0
  2   │  A1   │    1       1      │   --        0        1      │ accept A1
  3   │  B1   │    1       1      │   --        0        1      │ issue op1
 ...  │       │                   │  res0       1        1      │ result0 out (after latency)
```

Steady state: 2 input bytes/op (II=2), results draining 1/op in parallel.
**Best case** (`STICKY_CTRL=1`, `STICKY_B=1`, `READ_FULL=0`): 1 byte in, 1 byte
out → **II = 1 op/cycle** when the pipeline is full.

## 7. Reset and design selection (Tiny Tapeout)

1. Select the design in the TT multiplexer (`ctrl_sel_rst_n` / `ctrl_sel_inc`
   pulses) — handled by the TT API/firmware.
2. Pulse `rst_n` LOW for a few cycles, then release.
3. After reset: `in_count=0`, `out_busy=0`. Keep `STICKY_*=0` on the first
   operation to initialise `B`/`CTRL`.

## 8. Internal tie-offs (standalone on chip)

| Core signal | Value in the wrapper |
|-------------|----------------------|
| `issue_rd` | `0` (no register file on chip) |
| `wb_rd` | ignored |
| `flush` | `0` (never) |
| `wb_ready` | generated by the output serialiser (real back-pressure) |

`wb_ready` dropping (slow host draining) propagates back-pressure into the
pipeline and eventually lowers `IN_READY` — end-to-end elastic flow control, so
nothing is ever lost.
