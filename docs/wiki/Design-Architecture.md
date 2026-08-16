# Design architecture

## Format — FP8 E4M3

`[7]=sign  [6:3]=exponent (bias 7)  [2:0]=mantissa`. Zero and subnormals at
exp=0, Inf/NaN at exp=15. Largest finite = **240**, smallest normal ≈ 0.0156,
smallest subnormal ≈ 0.00195. Full encoding, opcode, rounding-mode, flag and
exception tables: [ISA Reference](ISA-Reference).

Two range facts drive several design decisions: the format holds only **4
significand bits** (3 stored + hidden), and it tops out at 240 — below `uint8`'s
255 but well above `int8`'s 127.

## Operations — 18, opcode = `ui_in[4:0]`

| op | name | op | name | op | name |
|----|------|----|------|----|------|
| 0 | ADD | 6 | MAX | 12 | NEG |
| 1 | SUB | 7 | ABS | 13 | COPYSIGN |
| 2 | MULT | 8 | CLASSIFY | 14 | CVT_F2I |
| 3 | DIV *(iterative)* | 9 | COMPARE | 15 | CVT_F2U |
| 4 | SQRT *(iterative)* | 10 | SCALB | 16 | CVT_I2F |
| 5 | MIN | 11 | ROUNDINT | 17 | CVT_U2F |

## Datapath — elastic pipeline

`tiny_fp8_unit` is a chain of **depth-1 elastic buffers**
(`fp8_handshake_reg`) wired by `fp8_elastic_pipeline`:

```
C0: unpack + pre-execute + execute + normalize ──▶ RA
C1: round                                       ──▶ RB
MUX special / normal                            ──▶ RC (output)
```

- **Fast ops** (add/sub/mul, special cases, direct ops, conversions) are
  single-cycle and fully pipelined.
- **DIV/SQRT** share one **iterative, variable-latency** unit (`fp8_div_iter`,
  ~1 digit/cycle). While it iterates the pipeline stalls its input, so results
  stay **in issue order**.
- Every stage is a `valid/ready` handshake, so several operations stay in flight
  and back-pressure never loses, duplicates or reorders data — proven, see
  [Formal Verification](Verification-Formal).

There are **three paths** to a result, selected by `pre_execute` and
`direct_ops`, and understanding which one an operation takes explains most of
the code:

| Path | Used by | Where |
|---|---|---|
| **Special** | NaN/Inf/zero inputs; resolved by value, never touches the datapath | `fp8_pre_execute` |
| **Direct** | min, max, abs, classify, compare, neg, copysign, roundint, fp8→int | `fp8_direct_ops` — takes precedence over special |
| **Datapath** | add, sub, mul, div, sqrt, scalb, int→fp8 | `execute → normalize → round` |

## The Tiny Tapeout wrapper in detail

`tt_um_fp8_fpu` contains **no arithmetic**. It is a protocol adapter, and it
exists for one reason: the core needs ~32 input and ~28 output bits, while Tiny
Tapeout provides 8 dedicated in, 8 dedicated out and 8 bidirectional — 24 total.

### The pin budget problem

```
tiny_fp8_unit needs:
  in  : issue_valid(1) A(8) B(8) opcode(5) rm(3) rd(5) wb_ready(1) flush(1) = 32
  out : result(8) flags(7) exceptions(5) rd(5) valid(1) ready(1) busy(1)    = 28

Tiny Tapeout gives:
  ui_in(8) + uo_out(8) + uio(8, each pin in OR out) + clk + rst_n           = 24 GPIO
```

### The solution — two independent byte streams

Rather than a fixed phase machine ("send 3 bytes, wait, receive 3 bytes"), the
wrapper runs **two handshakes that do not have to advance together**:

```
host ──ui_in[7:0]──▶  A, then B, then CTRL      (IN_VALID  / IN_READY)
host ◀─uo_out[7:0]──  result [, flags, exc]     (OUT_VALID / OUT_READY)
```

A transfer happens on any rising clock edge where `valid & ready` are both high.
Because the streams are independent, the host **keeps feeding new operands while
draining old results** — so several operations stay in the pipeline and the
steady-state cost approaches the number of bytes per operation rather than the
latency of one operation.

| Pin | Direction | Meaning |
|---|---|---|
| `ui_in[7:0]` | in | `DATA_IN` — byte stream: A → B → CTRL |
| `uo_out[7:0]` | out | `DATA_OUT` — byte stream: result → flags → exceptions |
| `uio_in[0]` | in | `IN_VALID` |
| `uio_out[1]` | out | `IN_READY` |
| `uio_out[2]` | out | `OUT_VALID` |
| `uio_in[3]` | in | `OUT_READY` |
| `uio_in[4]` | in | `STICKY_CTRL` — reuse last `{rm, opcode}` |
| `uio_in[5]` | in | `STICKY_B` — reuse last B |
| `uio_in[6]` | in | `READ_FULL` — 3 bytes out instead of 1 |
| `uio_out[7]` | out | `FPU_BUSY` |

`CTRL = {rm = ui_in[7:5], opcode = ui_in[4:0]}`, and **the CTRL byte issues the
operation** in the same cycle it is accepted.

### Sticky modes — why they exist

Bytes per operation are the throughput limit, not the pipeline:

```
in_needed  = 1 + (STICKY_B ? 0 : 1) + (STICKY_CTRL ? 0 : 1)   // 1..3
out_needed = READ_FULL ? 3 : 1
```

`STICKY_B` and `STICKY_CTRL` tell the wrapper to reuse the last B operand and
the last `{rm, opcode}`, so a loop doing "the same operation against the same
constant" — scaling a vector, applying an activation — costs **one byte in, one
byte out**, an initiation interval of 1. Send one full operation first to load
the holding registers, then raise the sticky bits and keep them stable.

`READ_FULL` chooses between the result byte alone and result + flags +
exceptions. Debug and verification use 3 bytes; production code that only wants
the number uses 1.

### Back-pressure is end-to-end

If the host stops consuming (`OUT_READY` low), the result FIFO fills, the
pipeline back-pressures, and `IN_READY` drops. Nothing is ever lost — the same
elastic contract the formal proofs cover. Full cycle-by-cycle description:
[Pin Protocol](Pin-Protocol).

### What this costs

Serialising is not free: three bytes in and three out means a minimum of three
cycles per operation in full mode, against a core that could accept one per
cycle. The wrapper is a consequence of the pin budget, not of the design — which
is exactly why [attaching the core to a CPU](RISC-V-Integration) bypasses it
entirely and talks to `tiny_fp8_unit` directly.

## Datapath widths

Three parameters in `header_fp8.v` control the internal buses. All three sit at
a **proven floor**; the reasoning and the structural limits are in
[Design Decisions](Design-Decisions).

| Parameter | Value | What it is |
|---|---:|---|
| `NRM_ACCW` | 10 | ADD/SUB alignment accumulator (was 26) |
| `NRM_MW` | 8 | pre-rounding bus — the only *registered* one (was 16) |
| `NRM_QDIV` | 5 | divider quotient fraction bits |

## Reference model

`Golden_model/fp8_math.py` is a value-exact (`Fraction`-based) IEEE-like
specification: it computes the true mathematical result and rounds once, with no
datapath and no intermediate error. The RTL is audited against it across **all
1,843,968 input combinations**, and the same model is the oracle for the UVM
scoreboard — one specification, several consumers.
