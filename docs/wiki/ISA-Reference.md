# ISA Reference — format, opcodes, rounding, flags

The definitive reference for the FP8 E4M3 encoding and the FPU's control fields.
All definitions come from [`src/header_fp8.v`](../../src/header_fp8.v) — this page
is the human-readable version of that header.

## FP8 E4M3 format

An 8-bit float laid out as `[sign 1b][exponent 4b][mantissa 3b]`, exponent
**bias = 7**:

```
 bit  7   6 5 4 3   2 1 0
     [S] [ exp(4) ] [mant(3)]
```

| Field | Bits | Meaning |
|-------|------|---------|
| sign | `[7]` | 0 = positive, 1 = negative |
| exponent | `[6:3]` | biased exponent, bias 7 (`2^(4-1) − 1`) |
| mantissa | `[2:0]` | 3 fractional bits + an implicit hidden bit (normals) |

### Special values

| Class | Exponent | Mantissa | Value |
|-------|----------|----------|-------|
| Zero | `0000` | `000` | ±0 |
| Subnormal | `0000` | ≠ `000` | ±mant × 2^(1−bias) = ±mant × 2⁻⁶ |
| Normal | `0001`…`1110` | any | ±1.mant × 2^(exp−bias) |
| Infinity | `1111` | `000` | ±Inf |
| NaN | `1111` | ≠ `000` | quiet NaN |

### Range (normals)

| | Encoding | Value |
|-|----------|-------|
| Smallest positive normal | `0 0001 000` | 1.0 × 2⁻⁶ ≈ **0.015625** |
| Largest positive normal | `0 1110 111` | 1.875 × 2⁷ = **240.0** |
| Smallest positive subnormal | `0 0000 001` | 0.001₂ × 2⁻⁶ ≈ **0.001953** |

### Encoding examples

| Value | Encoding | Hex |
|-------|----------|-----|
| 1.0 | `0 0111 000` | `0x38` |
| 2.0 | `0 1000 000` | `0x40` |
| 3.0 | `0 1000 100` | `0x44` |
| 6.0 | `0 1001 100` | `0x4C` |

## Opcodes (`opcode = ui_in[4:0]`, `OP_WIDTH = 5`)

| Opcode | Binary | Name | Operands | Result |
|-------:|--------|------|----------|--------|
| 0 | `00000` | ADD | A, B | FP8 A + B |
| 1 | `00001` | SUB | A, B | FP8 A − B |
| 2 | `00010` | MULT | A, B | FP8 A × B |
| 3 | `00011` | DIV | A, B | FP8 A ÷ B *(iterative)* |
| 4 | `00100` | SQRT | A | FP8 √A *(iterative)* |
| 5 | `00101` | MIN | A, B | FP8 min (IEEE-2019, NaN propagates) |
| 6 | `00110` | MAX | A, B | FP8 max (IEEE-2019, NaN propagates) |
| 7 | `00111` | ABS | A | FP8 \|A\| |
| 8 | `01000` | CLASSIFY | A | class enum `result[3:0]` = 0..9 |
| 9 | `01001` | COMPARE | A, B | one-hot `result[3:0]` = {unordered, gt, eq, lt} |
| 10 | `01010` | SCALB | A, n=B | FP8 A · 2ⁿ (n = B as signed int8) |
| 11 | `01011` | ROUNDINT | A | FP8 round-to-integral (per `rm`) |
| 12 | `01100` | NEG | A | FP8 negate(A): A with the sign bit flipped |
| 13 | `01101` | COPYSIGN | A, B | FP8 copySign(A,B): magnitude of A, sign of B |

Unary ops (SQRT, ABS, CLASSIFY, ROUNDINT, NEG) take A and ignore B. NEG and
COPYSIGN are pure bit-level sign operations (no exceptions, no NaN signalling).

**CLASSIFY enum** (`result[3:0]`): 0 sNaN · 1 qNaN · 2 −inf · 3 −normal ·
4 −subnormal · 5 −0 · 6 +0 · 7 +subnormal · 8 +normal · 9 +inf.

## Rounding modes (`rm = ui_in[7:5]`)

| rm | Binary | Name | Behaviour |
|---:|--------|------|-----------|
| 0 | `000` | NEAREST | round to nearest, ties to **even** |
| 1 | `001` | ZERO | truncate (toward zero) |
| 2 | `010` | UP | toward +∞ |
| 3 | `011` | DOWN | toward −∞ |
| 4 | `100` | ODD | round to nearest, ties to **odd** |

## Classification flags (`FLAG_WIDTH = 7`)

Per-result flags describing the output value:

| Bit | Name | Meaning |
|----:|------|---------|
| 6 | `FLAG_SNAN` | signaling NaN |
| 5 | `FLAG_QNAN` | quiet NaN |
| 4 | `FLAG_NAN` | any NaN |
| 3 | `FLAG_INF` | infinity |
| 2 | `FLAG_NORMAL` | normal number |
| 1 | `FLAG_SUBNORMAL` | subnormal |
| 0 | `FLAG_ZERO` | zero |

## Exception flags (IEEE-754, `EXC_WIDTH = 5`)

| Bit | Name | Raised when |
|----:|------|-------------|
| 4 | `EXC_INVALID_OP` | invalid operation: Inf−Inf, 0/0, Inf×0, input NaN |
| 3 | `EXC_DIV_ZERO` | finite ÷ 0 → ±Inf |
| 2 | `EXC_OVERFLOW` | result above the largest finite |
| 1 | `EXC_UNDERFLOW` | non-zero value collapses to zero when rounded |
| 0 | `EXC_INEXACT` | rounded result differs from the exact value |

Overflow behaviour depends on the rounding mode: NEAREST/UP(+)/DOWN(−) produce
Inf, while ZERO/ODD and the opposite side of UP/DOWN saturate at the largest
finite.

## CTRL byte

The control byte issued as the last input of an operation is
`{ rm = ui_in[7:5], opcode = ui_in[4:0] }`. See [Pin Protocol](Pin-Protocol) for
how it is streamed, and [Design Architecture](Design-Architecture) for the
datapath.

## Other header parameters

`FLAG_WIDTH=7`, `EXC_WIDTH=5`, `OP_WIDTH=5`, `RD_WIDTH=4`. The wide-ruler sizing
shared between execute and normalize: `NRM_G=20` (alignment guard),
`NRM_ACCW=26` (add/sub accumulator width), `NRM_QDIV=5` (divide quotient
fraction bits). Exponent limits: `EXP_MAX=1110` (14), `EXP_INF_NAN=1111`,
`EXP_ZERO_SUB=0000`.
