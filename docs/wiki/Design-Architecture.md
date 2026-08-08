# Design Architecture

## Format — FP8 E4M3

`[7]=sign  [6:3]=exponent (bias 7)  [2:0]=mantissa`. Zero/subnormal at exp=0,
Inf/NaN at exp=15. Largest normal = 240, smallest normal ≈ 0.0156. Full encoding,
opcode, rounding-mode, flag and exception tables: [ISA Reference](ISA-Reference).

## Operations (opcode = `ui_in[4:0]`)

| op | name | op | name |
|----|------|----|------|
| 0 | ADD | 7 | ABS |
| 1 | SUB | 8 | CLASSIFY |
| 2 | MULT | 9 | COMPARE |
| 3 | DIV *(iterative)* | 10 | SCALB |
| 4 | SQRT *(iterative)* | 11 | ROUNDINT |
| 5 | MIN | 12 | NEG |
| 6 | MAX | 13 | COPYSIGN |

## Datapath — elastic pipeline

The core (`tiny_fp8_unit`) is a chain of **depth-1 elastic buffers**
(`fp8_handshake_reg`) wired by `fp8_elastic_pipeline`:

```
C0: unpack + pre-execute + execute + normalize ──▶ RA
C1: round                                       ──▶ RB
MUX special/normal                              ──▶ RC (output)
```

- **Fast ops** (add/sub/mul, special cases, direct ops) are single-cycle and
  fully pipelined.
- **DIV/SQRT** use a shared **iterative, variable-latency** unit
  (`fp8_div_iter`, ~1 digit/cycle). While it iterates, the pipeline stalls input
  (`ready_out=0`), so results stay **in issue order**.
- Every stage is a `valid/ready` handshake, so multiple operations stay in
  flight and back-pressure never loses or reorders data (proven —
  [Verification-Formal](Verification-Formal)).

## Streaming wrapper — `tt_um_fp8_fpu`

Tiny Tapeout gives 8+8+8 pins, not enough for the core's wide handshake. The
wrapper **serialises** operands/results over two independent `valid/ready`
byte streams:

- `ui_in[7:0]` = input bytes (A, then B, then CTRL = `{rm, opcode}`).
- `uo_out[7:0]` = output bytes (result [, flags, exceptions]).
- `uio` bits = handshake + config: `IN_VALID`, `IN_READY`, `OUT_VALID`,
  `OUT_READY`, `STICKY_CTRL`, `STICKY_B`, `READ_FULL`, `FPU_BUSY`.

**Sticky** modes reuse the last B/CTRL to cut bytes/op; **READ_FULL** emits
result+flags+exceptions. Full protocol: [Pin Protocol](Pin-Protocol).

## Reference model

`Golden_model/fp8_math.py` is a value-exact (`Fraction`-based) IEEE-like
specification. The RTL is audited against it across all 1,310,720 cases, and it
doubles as the oracle for the UVM scoreboard.
