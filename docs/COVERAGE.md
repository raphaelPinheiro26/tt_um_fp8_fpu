# Golden-vector coverage / sign-off status

Reference model: `Golden_model/fp8_math.py` (exact rational arithmetic via
`Fraction` + IEEE-754 exception rules). DUT: `tt_um_fp8_fpu` — the taped-out
top level, driven through the streaming pin protocol exactly as the silicon
host would, in `READ_FULL` mode so that **result, flags and exceptions** are
all compared, in order, with deadlock detection.

FP8 E4M3 is small enough that the input space can be swept *completely*. Every
opcode below is exhaustive over its full operand space — there is no sampling
in any row of this table.

## Coverage

| Opcode | Vectors | Sweep | RM | Status |
|---|---:|---|---|---|
| ADD | 327,680 | 256×256 × 5 rm | yes | pass |
| SUB | 327,680 | 256×256 × 5 rm | yes | pass |
| MULT | 327,680 | 256×256 × 5 rm | yes | pass |
| DIV | 327,680 | 256×256 × 5 rm | yes | pass |
| NEG | 256 | 256 | n/a | pass |
| COPYSIGN | 512 | 256 × 2 sign donors | n/a | pass |
| **SQRT** | **1,280** | 256 × 5 rm | yes | **pass** |
| **MIN** | **65,536** | 256×256 | n/a | **pass** |
| **MAX** | **65,536** | 256×256 | n/a | **pass** |
| **ABS** | **256** | 256 | n/a | **pass** |
| **CLASSIFY** | **256** | 256 | n/a | **pass** |
| **COMPARE** | **65,536** | 256×256 | n/a | **pass** |
| **SCALB** | **327,680** | 256 × 256 (n as int8) × 5 rm | yes | **pass** |
| **ROUNDINT** | **1,280** | 256 × 5 rm | yes | **pass** |

| **CVT_F2I** | **1,280** | 256 × 5 rm | yes | **pass** |
| **CVT_F2U** | **1,280** | 256 × 5 rm | yes | **pass** |
| **CVT_I2F** | **1,280** | 256 × 5 rm | yes | **pass** |
| **CVT_U2F** | **1,280** | 256 × 5 rm | yes | **pass** |

Rows in bold were **not** part of the historical sign-off set. Total:
1,311,488 arithmetic + 527,360 extended + 5,120 conversions =
**1,843,968 exhaustive vectors, zero mismatches**.

Files:

- `Golden_model/vectors.hex` — arithmetic + sign ops (`gen_vectors_math.py`)
- `Golden_model/vectors_newops.hex` — the eight extended ops
  (`gen_vectors_math.py --new`)
- `Golden_model/vectors_cvt.hex` — the four integer conversions
  (`gen_vectors_math.py --cvt`)

## Integer conversions (CVT)

Four unary opcodes on operand A: `CVT_F2I` (fp8→int8), `CVT_F2U` (fp8→uint8),
`CVT_I2F` (int8→fp8), `CVT_U2F` (uint8→fp8).

**Semantics: RISC-V FCVT.** Round per the rounding mode *first*, then
range-check and saturate; out-of-range and NaN raise `invalid` and do **not**
raise `inexact`. IEEE-754 §7.2 leaves this result unspecified — it does not
forbid a choice, it declines to make one — so adopting the RISC-V value costs
nothing in standards compliance, makes the cv32e40x coupling direct (no
software fixup), and keeps the reference model *total*: every input has a
defined output, which is what allows exhaustive sign-off with no don't-care
cases.

Range facts that make the corners real, not hypothetical:

- E4M3 reaches ±240 but int8 stops at −128..127, so ~15 of the 256 codes
  saturate on `F2I`. `−128` is exactly representable in both and does not.
- 240 **fits** in uint8 (0..255), so `F2U` never overflows upward — only
  negatives saturate, to 0.
- 255 **exceeds** the largest finite fp8 (240), so `U2F` is the one conversion
  that can overflow, going to Inf or the largest finite per the rounding mode.
- A negative that rounds to zero (e.g. −0.4 under RNE) converts to 0 with
  `inexact` and **no** `invalid` — only a rounded value that is genuinely out
  of range saturates.

**Cost: +276 generic gates, 0 flip-flops.** The implementation reuses the
ROUNDINT shifter and rounding decision in `fp8_direct_ops` for fp8→int, and
for int→fp8 it injects the integer into the existing accumulator with
`ebase = G+4`, so `fp8_normalize` computes `e_real = msb` and the whole
LZC/shifter/rounder chain is reused unchanged. No new normalisation or
rounding hardware.

Integer 0 converts to **+0 always**, never −0, even in round-down — handled as
a special in `fp8_pre_execute` because the shared rounder would otherwise emit
−0 in that mode.

### Where the cost lands, and why it matters for routing

| Module | before | after | delta |
|---|---:|---:|---:|
| `fp8_direct_ops` | 728 | 917 | **+189** |
| `fp8_execute_comb` | 751 | 816 | +65 |
| `fp8_pre_execute` | 264 | 294 | +30 |
| `fp8_normalize` | 748 | 755 | +7 |

Two thirds of the cost lands in `fp8_direct_ops`, a single flat combinational
block — so it arrives as one **dense local cluster**, not spread out. Global
area barely moves (~2 %) but local density does, which is what drives detailed
routing congestion. Watch this table, not just the total, when adding logic.

Two micro-optimisations worth keeping in mind for anything added here:

- `mag > 127` is `mag[7]`; `mag > 128` is `mag[7] & |mag[6:0]`. Written with
  `>`, yosys builds two 8-bit carry chains inside the densest block of the
  design.
- The `E-3` left shift only ranges over 0..4, so a 3-bit shift amount is
  enough. A 4-bit one makes a 16-position barrel shifter for a 5-position
  need.

Together these removed 49 gates from `fp8_direct_ops` with no functional
change (all 5,120 vectors still pass).

## Why some opcodes are swept at rm=0 only

MIN, MAX, COMPARE, ABS and CLASSIFY do not read `rounding_mode` in the RTL —
in `src/fp8_direct_ops.v` the `do_round()` helper is called only from the
ROUNDINT branch. Emitting them once at rm=0 is therefore a complete sweep, not
a reduced one.

This was **verified empirically rather than assumed**: 98,048 cases of those
five opcodes were replayed with rm = 1, 2, 3 and 4 while keeping the rm=0
expected values, and all passed. The RTL is rounding-mode-invariant for them.

## How to reproduce

```bash
cd test

# arithmetic sign-off set (default file)
FP8_NVEC=0 make

# extended opcodes
FP8_VEC=../Golden_model/vectors_newops.hex FP8_NVEC=0 make
```

`FP8_NVEC=0` means "every vector in the file". Both runs also exercise the
back-pressure path (`FP8_NBP`), which randomises input bubbles and output
stalls to catch loss, duplication or reordering in the elastic pipeline.

Note: `test_sticky_ctrl_result_only` searches the vector file for ADD/nearest
cases and will fail if pointed at `vectors_newops.hex`, which contains none.
That is a testbench precondition, not a DUT failure — filter it out with
`COCOTB_TEST_FILTER=test_vectors_.*` when running the extended set.

## Datapath narrowing (NRM_G 20 → 4)

The ADD/SUB alignment accumulator was `NRM_ACCW = 26` bits (`NRM_G = 20`) for a
format with a **4-bit significand**. It was sized so that the alignment shift
was always exact: the largest possible exponent difference is 16 (`+7` for the
largest normal down to `-9` for the pre-normalized smallest subnormal), so with
20 guard bits nothing was ever discarded — and the sticky logic in
`fp8_execute_comb` was therefore dead code.

Two bugs had to be fixed before the accumulator could be narrowed:

1. **Sticky was injected into bit 0 of the accumulator, before normalisation.**
   On a cancelling subtraction the normaliser left-shifts, which dragged that
   bit up into the guard/round positions, where the rounder read it as an exact
   bit. Fixed by taking sticky out of `fp8_execute_comb` as a separate signal
   and letting `fp8_normalize` apply it *after* the shift, through the same
   `extra_sticky` port the divider's `remnz` already used.

2. **Sticky did not participate in the subtraction borrow.** Discarding bits
   makes the subtrahend larger, so the true result is *smaller* than
   `big - small_sh`; flagging "something was discarded" is not enough. The
   accumulator must borrow one ulp, which places the exact value in
   `(as_acc, as_acc+1)` — precisely what `sticky = 1` means to the rounder.
   Symptom: `0x01 + 0xB8` (2⁻⁹ − 1.0) in round-to-odd returned `0xB9`
   instead of `0xB7`.

With both fixed, `NRM_G = 4` (`NRM_ACCW = 10`) is bit-exact. That is the hard
floor: `fp8_normalize` zero-extends the divider quotient into the same bus, so
`NRM_ACCW >= NRM_QDIV + 5 = 10`.

## Bus narrowing (NRM_MW 16 → 8)

`norm_mant_wide` was a hardcoded 16-bit bus. Its useful content is 7 bits —
hidden, 3 mantissa, guard, round, sticky. The other 9 existed only so the
denormalisation shift in `fp8_round` (up to ~14 positions) would not push the
guard/round bits off the bottom. With the sticky field OR-reduced properly that
field can be minimal.

The bit positions are now derived from `NRM_MW` instead of being literals:
`[MW-1]` hidden, `[MW-2:MW-4]` mantissa, `[MW-5]` guard, `[MW-6]` round,
`[MW-7:0]` sticky. At `NRM_MW=16` the result is bit-identical to the previous
code, so the parameterisation itself is behaviour-preserving.

`NRM_MW = 8` is the floor: `fp8_normalize` injects the 8-bit MULT product into
the top of this bus (`ml_wide = {in_prod, ...}`). This is also the only
*registered* bus of the three parameters — it sits in the elastic pipeline's
`RA` register, so narrowing it is the one change here that saves flip-flops.

## Area

Technology-independent yosys synthesis (`proc; flatten; opt; techmap`):

| Config | Gates | DFF |
|---|---:|---:|
| `G=20`, `ACCW=26`, `MW=16` (original) | 5266 | 256 |
| `G=4`, `ACCW=10`, `MW=16` | 4357 | 256 |
| `G=4`, `ACCW=10`, `MW=12` | 4265 | 252 |
| `G=4`, `ACCW=10`, `MW=10` | 4204 | 250 |
| **`G=4`, `ACCW=10`, `MW=8` (current)** | **4079** | **248** |
| **delta vs original** | **−1187 (−22.5 %)** | **−8** |

### Measured result (sky130, LibreLane)

Generic gate counts turned out to be a **poor** proxy for cell area. The
hardening run gives:

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Core utilisation | 72.429 % | **67.641 %** | −4.79 pp (−6.6 % relative) |
| Wire length | 89 432 µm | **72 757 µm** | **−18.6 %** |
| Cells (excl. fill/tap) | 2396 | ~2238 *(derived)* | ~−158 |

The 22.5 % generic-gate reduction became a **6.6 %** area reduction. The
removed logic was mostly muxes and simple gates from the shifters, which map to
small sky130 cells, while what remains concentrates flip-flops and complex
cells. Scaling generic gate counts by a single ratio was wrong by roughly 3×.

**Lesson: measure with `stat -liberty` against the PDK, not with generic gate
counts.** See `docs/COMB-OPT.md`.

The result that mattered more was not area but **routing**: 16.7 mm less wire
on a design that already needed `GRT_ALLOW_CONGESTION: 1` at 72 % utilisation.
That raises the practical utilisation ceiling, which is what actually gates how
much new logic can be added.

Budget for new features, on a fixed 1×2 die of ~3309 cells capacity:

| Ceiling | Usable cells | Budget over ~2238 |
|---|---:|---:|
| 82 % | 2713 | ~475 |
| 85 % | 2813 | ~575 |

### Validation status of the narrowed datapath

At `NRM_G=4`, `NRM_ACCW=10` (accumulator only):

| Opcode | Vectors | |
|---|---:|---|
| ADD + SUB | 655,360 | complete, all 5 rounding modes |
| MULT | 327,680 | complete |
| SQRT, ROUNDINT, ABS, CLASSIFY, NEG, COPYSIGN | 3,840 | complete |
| DIV | 122,880 / 327,680 | 37.5 % sampled |

At `NRM_MW=8` (full current configuration):

| Set | Vectors | |
|---|---:|---|
| every case whose expected result is subnormal or zero | 322,361 | complete, all opcodes and modes — this is the set the denormalisation shift actually stresses |
| ADD + SUB, round-to-odd | 131,072 | complete |
| SQRT, ROUNDINT, ABS, CLASSIFY, NEG, COPYSIGN | 3,840 | complete |

**Still to run at the current configuration:** the full 1.84M sweep. The
subsets above target the paths the changes actually touch, but the sign-off
claim requires the whole thing:

```bash
cd test && ./regress.sh          # all 14 opcodes, ~1.84M vectors
```

Do this before re-hardening, and again with `GATES=yes` after.

## Known gaps

- **Gate-level.** The table above is RTL simulation. The same two vector sets
  should be replayed with `make GATES=yes` once the hardening run produces
  `gate_level_netlist.v`. Until then the extended opcodes are signed off at RTL
  only.
- **CVT / FMA.** Not implemented; nothing to cover yet.
- **Historical note.** A real SCALB bug was found by the pyuvm constrained-random
  testbench (see the comment in `src/fp8_elastic_pipeline.v`) precisely because
  SCALB was outside the golden-vector sign-off set. That gap is now closed.
