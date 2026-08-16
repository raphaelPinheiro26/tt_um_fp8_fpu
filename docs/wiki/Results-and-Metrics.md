# Results and metrics

Every number here was measured, not estimated — and where an estimate was made
first and turned out wrong, both are shown. Reproduce any of it with the
[Area Runbook](Area-Runbook).

---

## Headline

| Metric | Value |
|---|---|
| Format | FP8 E4M3 (1 sign, 4 exponent, 3 mantissa, bias 7) |
| Operations | **18** — arithmetic, comparison, manipulation, integer conversion |
| Rounding modes | 5 (nearest-even, toward-zero, up, down, nearest-odd) |
| Process | ChipFoundry `sky130A`, 1×2 Tiny Tapeout tiles |
| Core utilisation | **71.6 %** |
| Wire length | 96 460 µm |
| Detailed routing | **0 violations** |
| Setup / hold worst slack | +44.65 ns / +0.116 ns @ 100 ns period |
| Critical path | 55.35 ns |
| Total power | ≈ 2.3 mW (default switching activity) |
| Verification | **1 843 968 vectors, exhaustive, RTL *and* gate level** |

Earlier silicon: the same design hardened on GlobalFoundries `gf180mcu` at
2×2 tiles, 3842 cells, 40.8 % utilisation. That chip is fabricated.

---

## Area, change by change

The project went from 2×2 tiles on gf180 to 1×2 on sky130 through two
deliberate optimisation passes, then paid a small amount back for the
conversions.

### Pass 1 — pipeline and divider (earlier work)

Depth-1 elastic registers instead of 2-deep skid buffers, and `NRM_QDIV`
10 → 5. Removed roughly 200 flip-flops. This is what made 1×2 possible at all.

### Pass 2 — datapath width analysis

Two parameters, both reduced to a *proven* floor rather than a guessed one.

| Configuration | Generic gates | DFF |
|---|---:|---:|
| `G=20, ACCW=26, MW=16` (before) | 5266 | 256 |
| `G=4, ACCW=10, MW=16` | 4357 | 256 |
| `G=4, ACCW=10, MW=12` | 4265 | 252 |
| `G=4, ACCW=10, MW=10` | 4204 | 250 |
| **`G=4, ACCW=10, MW=8` (after)** | **4079** | **248** |
| **delta** | **−1187 (−22.5 %)** | **−8** |

Flip-flops barely move because the accumulator is purely combinational; only
`norm_mant_wide` is registered, so only narrowing *that* saves state.

Physically, on sky130:

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Core utilisation | 72.43 % | 67.64 % | **−4.79 pp** |
| Wire length | 89 432 µm | 72 757 µm | **−18.6 %** |
| Cells (excl. fill/tap) | 2396 | ~2238 | ~−158 |

> **A 22.5 % gate reduction produced a 6.6 % area reduction.** Generic gate
> counts are *not* proportional to standard-cell area — the logic removed was
> mostly muxes from shifters, which map to small cells, while what remained
> concentrates flip-flops and complex cells. A pre-hardening estimate of −520
> cells was wrong by about 3×. Measure with `stat -liberty` against the PDK, not
> with generic gates. See [Combinational Optimization](Combinational-Optimization).

The result that mattered more than area was **routing**: 16.7 mm less wire on a
design that already needed `GRT_ALLOW_CONGESTION` at 72 %.

### Pass 3 — integer conversions (cost, not saving)

| Module | Before | After | Delta |
|---|---:|---:|---:|
| `fp8_direct_ops` | 728 | 917 | **+189** |
| `fp8_execute_comb` | 751 | 816 | +65 |
| `fp8_pre_execute` | 264 | 294 | +30 |
| `fp8_normalize` | 748 | 755 | +7 |
| **total** | | | **+276 gates, 0 flops** |

Cheap because it reuses existing hardware: fp8→int borrows the ROUNDINT shifter
and rounding decision; int→fp8 injects the integer into the accumulator with
`ebase = G+4`, so the existing LZC, shifter and rounder do the work unchanged.

**Two thirds of the cost landed in one flat combinational block**, and that —
not the total — is what broke detailed routing on the first attempt. Watch the
per-module table when adding logic, not just the total.

---

## Timing

At the declared 10 MHz the design has enormous margin (+44.65 ns), which is
also why it reports 988 max-slew violations: with that much slack the resizer
has no reason to strengthen any driver. Both improve when the clock tightens.

| | Value |
|---|---|
| Declared clock | 10 MHz (100 ns) |
| Setup worst slack | +44.65 ns |
| Critical path | 55.35 ns |
| Naive Fmax | ≈ 18 MHz |
| Hold worst slack | +0.116 ns |

The naive Fmax understates the design. A clock sweep (`flow/sweep_clock.py`)
pushes the tool to actually optimise the path; earlier sweeps on the previous
netlist found a floor well below the relaxed-clock figure. **Re-run the sweep
on the current netlist before quoting an Fmax.**

The floor is the combinational C0 stage — unpack → pre-execute → execute →
normalize, including the barrel shifter. Buffering cannot cross it; pipelining
C0 is the lever for higher frequency.

## Power

| | Value |
|---|---|
| Total | ≈ 2.3 mW |
| Dynamic (internal) | ≈ 1.0 mW |
| Dynamic (switching) | ≈ 1.2 mW |
| Static (leakage) | ≈ 34 nW |

> `power__total` comes from OpenSTA with **default switching activity**, so the
> dynamic part is an estimate, not a measurement. Leakage is workload-independent
> and trustworthy. For real dynamic power on a specific workload, feed a
> VCD/SAIF from a gate-level simulation into STA.

## Verification cost

| Level | Vectors | Rate | Wall clock (12 cores) |
|---|---:|---|---|
| RTL | 1 843 968 | ~403 vec/s per job | tens of minutes |
| Gate level | 1 843 968 | ~165 vec/s per job | 40–50 minutes |

Gate level is only **2.4×** slower than RTL on this design — not the 10–50×
often quoted — which is why the full exhaustive sweep is affordable at both
levels and no sampling was needed.

## Remaining budget

The die is fixed by the tile count:

```
capacity  = 2396 / 0.72429 = ~3309 cells
current   = 3309 × 0.7157  = ~2368 cells
```

| Routing ceiling | Usable | Free |
|---|---:|---:|
| 82 % (conservative) | 2713 | **~345 cells** |
| 85 % | 2813 | ~445 cells |

Which is why the exact accumulator (350–450 cells) is deferred to the FPGA
build rather than squeezed in — see [Design Decisions](Design-Decisions).
