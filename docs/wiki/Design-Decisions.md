# Design decisions

Every non-obvious choice in this project, the alternative that was rejected,
and the reason. Written so that whoever inherits the design — including the
author in six months — does not have to re-derive it, and does not undo it by
accident.

Ordered roughly by how much they matter.

---

## 1. Exhaustive verification instead of sampling

**Decision.** Every operation is signed off by replaying *all* 1,843,968
possible `(A, B, opcode, rounding-mode)` combinations against a `Fraction`-exact
reference model — at RTL and against the post-place-and-route netlist.

**Alternative rejected.** Constrained-random plus directed corner cases, which
is what floating-point hardware normally gets, because in FP32 a binary
operation has 2⁶⁴ input combinations and enumeration is impossible. That
impossibility is precisely why the classical literature verifies FP hardware
with theorem proving (ACL2 at AMD, HOL Light at Intel) rather than by testing.

**Why.** In a minifloat, enumeration comes back within reach — and it is both
cheaper and more direct than a machine-checked proof. It is also the enabler
for decision #2: you can only narrow a datapath aggressively if you can prove
bit-exactness over *everything*.

**Cost.** ~40–50 minutes of wall clock at gate level on 12 cores. Cheap.

## 2. Datapath widths reduced to a measured floor

**Decision.** `NRM_ACCW` 26 → 10, `NRM_MW` 16 → 8, `NRM_G` 20 → 4.

**Alternative rejected.** Deriving the minimum widths analytically on paper.

**Why.** The original `NRM_G = 20` was itself an analytical derivation: sized so
the alignment shift would always be exact, because the largest possible exponent
difference is 16. It was correct and it was 2.6× larger than necessary. Worse,
it made the sticky logic *dead code* — no bit was ever discarded — which hid two
real bugs for the design's entire life (see #3).

The floor was instead found by parameterising the width, sweeping it downward,
and letting the exhaustive vector set say where it breaks. That is not laziness;
it is using the strongest available oracle instead of the most confident
argument.

**Do not reduce further.** `NRM_ACCW ≥ NRM_QDIV + 5 = 10` because
`fp8_normalize` zero-extends the divider quotient onto the same bus, and
`NRM_MW ≥ 8` because the multiplier injects its 8-bit product at the top of it.
Both floors are structural and are commented in `header_fp8.v`.

**Result.** −1187 generic gates (−22.5 %), −8 flops, −18.6 % wire.

## 3. Sticky is a separate signal, and it borrows

Two bugs, both invisible while `NRM_G = 20` made sticky unreachable.

**Bug A — sticky was injected into bit 0 of the accumulator, before
normalisation.** On a cancelling subtraction the normaliser shifts left, which
dragged that bit up into the guard/round positions where the rounder read it as
an exact bit. **Fix:** sticky leaves `fp8_execute_comb` as its own signal and
`fp8_normalize` applies it *after* the shift, through the same `extra_sticky`
port the divider's remainder already used.

**Bug B — sticky did not participate in the subtraction borrow.** Discarding
bits makes the subtrahend larger, so the true result is *smaller* than
`big − small_shifted`. Flagging "something was discarded" is not enough; the
accumulator must borrow one ulp, which places the exact value in
`(acc, acc+1)` — precisely what `sticky = 1` means to the rounder.

Concrete symptom: `0x01 + 0xB8` (2⁻⁹ − 1.0) in round-to-odd returned `0xB9`
instead of `0xB7`.

**Lesson worth keeping.** Guard bits generous enough to make sticky unnecessary
do not remove the sticky logic — they remove the *test coverage* of it. Dead
code in a datapath is not free; it is a defect waiting for a configuration
change.

## 4. Integer conversions use RISC-V FCVT semantics

**Decision.** `CVT_F2I` / `CVT_F2U` round by the current mode **first**, then
range-check and saturate: out-of-range and NaN produce the saturated value and
raise `invalid`, and do *not* raise `inexact`.

**Alternative rejected.** "Strict IEEE-754", which turns out not to be a real
alternative: IEEE-754 §7.2 signals `invalid` and leaves the result
**unspecified**. It declines to choose; the hardware still has to emit some bit
pattern.

**Why RISC-V's choice.** Three reasons, none of them about standards
compliance:

1. The cv32e40x coupling becomes direct — whatever the FPU returns is what the
   ISA specifies, with no software fix-up on every conversion.
2. It keeps the reference model **total**: every input has a defined output, so
   the exhaustive sign-off has no don't-care holes. An unspecified result would
   weaken the strongest claim the project makes.
3. It costs about 20 cells.

**Corner cases that are real, not hypothetical.** E4M3 reaches ±240 while int8
stops at −128..127, so ~15 of the 256 codes saturate on `F2I`; 240 *fits* in
uint8 so `F2U` never overflows upward; 255 *exceeds* the largest finite fp8, so
`U2F` is the one conversion that can overflow to infinity. A negative that
rounds to zero (−0.4 under RNE) converts to 0 with `inexact` and **no**
`invalid` — only a rounded value genuinely out of range saturates.

**Integer 0 converts to +0 always**, never −0, even in round-down. Handled as a
special in `fp8_pre_execute` because the shared rounder would otherwise emit −0
in that mode.

## 5. Conversions are unary on A

**Decision.** All four conversions take operand A and ignore B.

**Why.** It matches the streaming wrapper's cost model — a unary op with sticky
B needs fewer bytes per operation — and it matches every other unary op in the
ISA. For `I2F`/`U2F` this means `fp8_pre_execute` must be told that A is an
*integer*, not an FP8 code, before any NaN/Inf test runs; `0x79` there is the
number 121, not a NaN. That branch sits first in the decision chain for exactly
this reason.

## 6. The exact accumulator is deferred to FPGA

**Decision.** No FMA or wide accumulator in this tapeout.

**Alternatives considered.**

| Option | Cells | Verdict |
|---|---:|---|
| Narrow FMA, fp8×fp8+fp8→fp8 | 250–400 | Numerically useless: swamps past N≈16 and overflows at 240. A GEMV of any realistic size saturates. |
| Reduced fixed accumulator (~28 bit) | 350–450 | Marginal against ~345 free cells |
| Exact Kulisch accumulator (~40 bit) | 500–800 | Does not fit |

**Why deferred rather than squeezed.** The remaining budget is ~345 cells at a
conservative 82 % routing ceiling. Entering a shuttle at the absolute limit with
two weeks left is how deadlines are missed. On FPGA the accumulator can be
implemented, measured and compared without an area ceiling — which is a better
experiment anyway, and it motivates the next tapeout.

**Note for whoever implements it.** Accumulating in E4M3 is the trap: with only
4 significand bits, once the accumulator exceeds a partial product by 16× the
product disappears entirely. Every production FP8 deployment multiplies in FP8
and accumulates wider. A fixed-point accumulator of ~40 bits covers *every*
possible FP8 product exactly with no rounding at all during accumulation, and is
cheaper than a floating-point accumulator of the same range.

## 7. Divide and square root share one iterative unit

**Decision.** `fp8_div_iter` serves both, 1 digit/cycle, variable latency,
absorbed by the elastic handshake.

**Why it is not worth revisiting.** It costs roughly 45 flops and a 12-bit
compare-subtract. The README once claimed the divide path was combinational and
that this was what forced the conservative 10 MHz; that claim was stale. There
is nothing to recover here — measure before optimising.

## 8. `PL_TARGET_DENSITY_PCT = 75`

**Decision.** Raised from the Tiny Tapeout stock value of 60.

**Why.** At 60, adding the conversions produced a placement that detailed
routing could not resolve: violations fell from 7641 to 3075 over sixteen
iterations and then *doubled* to 6690 on the seventeenth, dominated by shorts on
met1/met2. Raising the target produced a different placement that routes to
**0 violations**.

**Honest caveat.** The mechanism first proposed — "a target below the achieved
utilisation is infeasible" — does not hold: the pre-conversion run had 67.6 %
utilisation with a target of 60 and routed cleanly. What actually happened is
narrower: the conversions pushed *that particular* placement past routability,
and changing the target produced one that fit. The fix is real; the explanation
was not.

**Consequence to remember.** This is why the design has only **four** signal
routing layers: met5 and part of met4 are reserved for the power distribution
network. Congestion at 70 % utilisation is normal in that situation and is about
local density, not total area.

## 9. Verification layers are deliberately redundant

Five layers — golden vectors, block-level cocotb, constrained-random pyuvm,
formal, DFT — and they are not duplicates.

**Evidence, not theory.** A real SCALB bug was found by the pyuvm testbench
precisely because SCALB was outside the golden-vector set at the time. That is
the whole justification for the coverage pass that produced this design.

The same gap nearly repeated with the conversions: after they were implemented,
the pyuvm opcode pool was still `[0..13]` and `sim/cocotb/unit` did not even
compile. **Adding an instruction requires auditing every layer**, not just the
one you are looking at.

**A property worth copying.** The formal wrapper leaves `opcode` as a free
5-bit input rather than enumerating the instruction set. Its protocol
properties therefore extended to the four new conversions automatically, with
no change to the proof. Protocol properties that do not enumerate the ISA age
well; ones that do, do not.

---

## Things that turned out to be wrong

Kept deliberately — the corrections are more useful than the conclusions.

| Belief | Reality |
|---|---|
| Generic gate count is a proxy for cell area | Wrong by ~3×. Use `stat -liberty`. |
| Gate-level simulation is 10–50× slower than RTL | 2.4× on this design. The full sweep was affordable. |
| The combinational divider was the area hog | It was already iterative and costs ~45 flops. |
| A placement density target below utilisation is infeasible | The previous run disproves it. |
| The committed `vectors.hex` was a 30k sample | It was the full 1.3M set; the README was stale. |
