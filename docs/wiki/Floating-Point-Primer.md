# How floating point works, and why E4M3

Written for someone who has to *build* or *verify* a floating-point unit, not
just use one. It starts from first principles and ends at the exact format this
project implements.

---

## 1. The problem floating point solves

Fixed-point arithmetic puts the binary point at a fixed position. With 8 bits
and the point in the middle you get values from 0.0625 to 15.9375 in steps of
0.0625 — uniform spacing, and a **dynamic range of about 256:1**.

Neural network weights and activations do not look like that. Weights cluster
near zero, gradients span many orders of magnitude, and a single layer may hold
values differing by a factor of 10⁵. Uniform spacing wastes codes where nothing
lives and runs out of range where things do.

Floating point trades *uniform* spacing for *relative* spacing: a value is
stored as

```
value = (-1)^sign  ×  significand  ×  2^exponent
```

so the step between neighbours grows with the magnitude. The relative precision
stays roughly constant across the whole range. That is the entire idea — every
other rule exists to make it well-defined.

## 2. Anatomy of a floating-point number

Three fields packed into one word:

```
 ┌───┬───────────────┬────────────────┐
 │ S │   exponent    │    mantissa    │
 └───┴───────────────┴────────────────┘
   1        E bits         M bits
```

**Sign** — 1 = negative. Sign-magnitude, not two's complement, which is why
negating is a single bit flip and why `+0` and `−0` are distinct encodings.

**Exponent, stored biased.** To represent negative exponents without a second
sign bit, a constant *bias* is added: `bias = 2^(E-1) − 1`. With E=4 the bias is
7, so the stored field 0111 means exponent 0, 1000 means +1, 0110 means −1. A
useful side effect: with the exponent in the high bits and a bias, comparing
positive floats as integers gives the right answer.

**Mantissa and the hidden bit.** A normalised binary number always starts with
1 (`1.0110…`), so that leading 1 is not stored. M stored bits give M+1 bits of
precision — free accuracy, at the cost of needing a special case for zero.

## 3. Normals, subnormals, and the exponent extremes

The two extreme exponent fields are reserved, which gives four classes:

| Exponent field | Mantissa | Meaning | Value |
|---|---|---|---|
| all zeros | zero | **zero** | ±0 |
| all zeros | non-zero | **subnormal** | `0.mantissa × 2^(1−bias)` |
| anything else | any | **normal** | `1.mantissa × 2^(exp−bias)` |
| all ones | zero | **infinity** | ±∞ |
| all ones | non-zero | **NaN** | not a number |

**Subnormals** exist to fill the gap between zero and the smallest normal. Without
them there is a jump: the smallest normal is 2^(1−bias), and the next value down
would be zero — a hole far larger than the spacing on either side. Subnormals
drop the hidden bit and fill that gap linearly, so `a − b == 0` if and only if
`a == b`. This is called **gradual underflow**, and it costs real hardware: the
implicit bit is no longer implicit, so every unpack must handle both cases.

This unit implements subnormals fully, in both directions.

## 4. Precision is relative, and that is the point

Because the exponent scales the spacing, the gap between neighbours doubles at
every power of two. The quantity that matters is not absolute error but **ulp**
(unit in the last place) — the distance to the next representable value.

Between 1.0 and 2.0 in this format there are 8 values, spaced 0.125 apart.
Between 128 and 240 they are spaced 16 apart. The *relative* step is between
6.25 % and 12.5 % everywhere.

That relative step is what a low-precision format is really buying or spending.
Three mantissa bits means roughly **one decimal digit** of precision.

## 5. Rounding — and why guard, round and sticky exist

Almost no arithmetic result is representable. `1.0 + 0.001953125` lands between
two neighbours, and the hardware must choose one. IEEE-754 requires the choice
to be *correct*: the result must be as if computed exactly and then rounded once.

This unit implements five modes:

| Mode | Rule |
|---|---|
| **Nearest-even** | Nearest; on an exact tie, the one with even last bit. The default — ties-to-even avoids the statistical drift that ties-away introduces. |
| **Toward zero** | Truncate. |
| **Toward +∞** | Round up. |
| **Toward −∞** | Round down. |
| **Nearest-odd** | Nearest; ties to odd. Useful for avoiding double-rounding error when results are re-rounded later. |

To decide correctly the hardware cannot simply discard the extra bits. It needs
three pieces of information about what was thrown away:

- **Guard (G)** — the first discarded bit
- **Round (R)** — the second
- **Sticky (S)** — the OR of *everything* below

Sticky is what makes "exactly halfway" distinguishable from "just above
halfway". Getting it wrong produces errors that only appear in the directed
rounding modes, and only on specific operand pairs — which is exactly what
happened in this project: two sticky bugs lived undetected for the design's
entire life because the guard field was wide enough that no bit was ever
actually discarded. See [Design Decisions](Design-Decisions).

## 6. Exceptions

Five sticky flags, raised per operation and accumulated by software:

| Flag | Raised when |
|---|---|
| **Invalid** | The operation has no sensible answer: `0/0`, `∞−∞`, `sqrt(−1)`, converting NaN to integer |
| **Divide by zero** | Finite non-zero divided by zero — the result is a correctly-signed infinity |
| **Overflow** | Result magnitude too large; goes to ∞ or the largest finite, depending on mode |
| **Underflow** | Result too small and inexact |
| **Inexact** | The result had to be rounded — by far the most common |

They are *sticky*: raised, never cleared by hardware, so software can check once
after a computation instead of after every instruction.

---

## 7. This format — E4M3

**E4M3** = 4 exponent bits, 3 mantissa bits, 1 sign bit. Bias 7.

```
 bit  7    6 5 4 3     2 1 0
     [S]  [ exp(4) ]  [mant(3)]
```

| Quantity | Value |
|---|---|
| Largest finite | **240** = `1.875 × 2⁷` (`0x77`) |
| Smallest normal | 0.015625 = `2⁻⁶` (`0x08`) |
| Smallest subnormal | ≈ 0.001953 = `2⁻⁹` (`0x01`) |
| Precision | 4 significand bits ≈ 1 decimal digit |
| Relative spacing | 6.25 % – 12.5 % |
| Dynamic range | ≈ 123 000 : 1 |
| Finite encodings | 240 (239 distinct values — ±0 coincide) |
| Infinities | 2 |
| NaN encodings | 14 |

Landmark encodings:

| Value | Encoding | Hex |
|---|---|---|
| 1.0 | `0 0111 000` | `0x38` |
| 2.0 | `0 1000 000` | `0x40` |
| 3.0 | `0 1000 100` | `0x44` |
| 6.0 | `0 1001 100` | `0x4C` |
| 240 (max) | `0 1110 111` | `0x77` |
| +∞ | `0 1111 000` | `0x78` |
| NaN | `0 1111 xxx` (xxx≠0) | `0x79`–`0x7F` |

### Why E4M3 and not E5M2

The two FP8 formats in common use split the same 8 bits differently:

| | exponent | mantissa | Trade |
|---|---|---|---|
| **E4M3** | 4 | 3 | More precision, less range — **inference, weights, activations** |
| **E5M2** | 5 | 2 | More range, less precision — **training, gradients** |

Gradients span enormous magnitudes and tolerate coarse precision, so training
favours E5M2. Weights and activations are bounded but benefit from every bit of
precision, so inference favours E4M3. This unit implements E4M3.

---

## 8. ⚠ Two different things are called "E4M3"

**This matters for any comparison against published FP8 hardware, and it is easy
to miss.**

This design follows the **IEEE-754 convention**: the all-ones exponent is
reserved for infinities and NaN, exactly as in binary16/32/64. Consequence:
the largest finite value is **240**.

The **OCP FP8 / industry E4M3** (as proposed by Micikevicius et al. and adopted
in the OCP specification) *deviates* from IEEE here. It reclaims most of that
exponent for finite numbers: there are **no infinities**, and only the
all-ones-exponent/all-ones-mantissa pattern is NaN. Consequence: its largest
finite value is **448**, not 240 — nearly one extra binade of range, bought by
giving up infinity representation.

| | This design | OCP FP8 E4M3 |
|---|---|---|
| Infinities | yes (`0x78`, `0xF8`) | **no** |
| NaN encodings | 14 | 2 (one per sign) |
| Largest finite | **240** | **448** |
| Follows IEEE-754 special-value convention | yes | no |

Neither is wrong — they are different points in the design space. IEEE
conformance buys uniform special-value semantics and makes the unit a
drop-in for generic floating-point software; the OCP choice buys range, which
matters when the format is only ever fed tensors.

**Practical consequences to keep in mind:**

- When comparing area or performance against published FP8 units, check which
  variant they implement. A unit without infinity handling has *less* work to do
  in `pre_execute` and the rounder overflow path.
- Numerical results are not directly comparable either: a value of 300 is finite
  in OCP E4M3 and overflows here.
- State explicitly in any write-up that this is an **IEEE-style E4M3**. A
  reviewer familiar with the OCP specification will otherwise read "E4M3" as the
  other format and flag the 240 as an error.

> Verify the OCP figures against the current specification before citing them —
> the details above are the widely reported ones, but the spec is the authority.

---

## 9. Why FP8 at all

Halving the width of every weight, activation and interconnect roughly halves
memory traffic and multiplier area — and in a modern accelerator, moving data
costs far more energy than the arithmetic. Networks tolerate it: inference in
8-bit floating point is close to lossless for most models, and 8-bit *floating*
point handles the wide per-tensor dynamic range better than 8-bit *integer*
quantisation, without needing per-channel scale factors.

There is one thing FP8 cannot do, and it shapes hardware design: **you cannot
accumulate in it.** With 4 significand bits, once a running sum exceeds an
incoming term by 16× the term vanishes entirely, and the sum saturates at 240
long before a realistic dot product finishes. Every production FP8 deployment
multiplies in FP8 and accumulates wider. That constraint is why this project
treats the accumulator as a separate design problem — see
[Design Decisions](Design-Decisions).

## 10. One property that only exists at this size

The entire input space of a binary FP8 operation is 256 × 256 × 18 opcodes × 5
rounding modes ≈ 1.8 million cases. That fits in an afternoon of simulation.

The same enumeration in FP32 would be 2⁶⁴ cases per operation — which is why
floating-point hardware is classically verified by theorem proving rather than
by testing. In a minifloat, **exhaustive verification becomes possible again**,
and it is both cheaper and more direct than a machine-checked proof. That
property is the foundation of this project's verification strategy:
[Coverage & Sign-off](Coverage-and-Signoff).
