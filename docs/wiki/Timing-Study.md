# Timing & Optimization Study

Characterisation of the taped-out FP8 FPU and the timing-optimisation
opportunities found via clock sweep + STA analysis. **The chip ships as-is:** it
meets the declared 10 MHz with large margin. This is the *optimisation /
future-work* chapter — where the frequency ceiling is, why, and the cheapest ways
to raise it.

> **Note.** The numbers below are from the **earlier characterization run**
> (5 470 total cells / 161 flops / 76.5 % util). The latest GDS run reports
> 2 396 logic cells, 227 `dfrtp` flops and 72.4 % util (see
> [Hardening & Metrics](Hardening-and-Metrics)); the timing/power analysis here
> has not yet been re-extracted on that netlist.

## 1. Baseline (LibreLane, `CLOCK_PERIOD = 100 ns`)

| Metric | Value |
|--------|------:|
| Process / PDK | sky130A (1.8 V) · 1×2 tiles |
| Std-cell instances | 5 470 |
| Cell / die area | 34 255 / 36 347 µm² |
| Core utilization | 76.5 % |
| Flip-flops | 161 |
| Setup / hold worst slack | +47.06 ns / +0.12 ns (@10 MHz) |
| Total power | ≈ 2.3 mW *(default switching activity)* |
| Max slew / cap violations | 742 / 0 |

Meets 10 MHz with +47 ns setup margin. DRC/LVS run in the TT precheck.

## 2. Clock sweep (`flow/sweep_clock.py`)

Re-hardened at tighter periods. **No swept point fully closes timing** — but the
*achieved* critical path (`period − setup_slack`) shows how far the tool squeezes
the logic under pressure:

| Target period (ns) | Target f (MHz) | Setup slack (ns) | Achieved path (ns) | Power (mW) |
|---:|---:|---:|---:|---:|
| 40 | 25.0 | −0.95 | **40.95** | 5.73 |
| 30 | 33.3 | −1.03 | 31.03 | 7.71 |
| 25 | 40.0 | −1.43 | 26.43 | 9.98 |
| 20 | 50.0 | −5.70 | 25.70 | 12.99 |
| 16 | 62.5 | −9.22 | 25.22 | 16.41 |
| 13 | 76.9 | −10.58 | 23.58 | 20.12 *(harden rc=1)* |

**Findings:**
- At a relaxed target the path is left long (~52.9 ns at 100 ns → naive
  18.9 MHz); under pressure it squeezes to a **floor ≈ 24 ns**.
- **Fmax: as-is ≈ 24 MHz, ceiling ≈ 40 MHz** (≈2× the naive estimate).
- Loose targets (25-40 ns) miss closure by only ~1 ns → a hold-fixing/margin
  artifact, not the datapath.
- **Power scales ~linearly with frequency, ≈ 0.28 mW/MHz** (default activity).
- The 13 ns point failed to harden (`rc=1`) — excluded from conclusions.

## 3. Critical-path analysis (post-PnR STA, 25 ns)

Worst setup path, slack **−1.43 ns**:

```
Startpoint: ui_in[5]   (INPUT PORT, +5 ns input external delay)
Endpoint:   _3540_     (pipeline flip-flop, dfrtp)
```

The path is **pin → wrapper issue logic → core C0 → register**: from an input
pin, through the wrapper's *combinational last-byte issue* (the `II == bytes`
throughput trick), through the whole C0 combinational datapath (unpack → execute
→ normalize), into the RA register — all in one cycle. Breakdown: ~5 ns input
external delay (20 % of a 25 ns budget), ~5→9 ns wrapper issue muxing, ~9→27 ns
C0 arithmetic. Flow-inserted buffers and 742 max-slew nets add further delay.

**Conclusion:** the bottleneck is *not* the C0 arithmetic alone — it is that a
single cycle spans **input pin + external delay + combinational issue + full C0**.

## 4. Optimisation roadmap (future work)

Ordered by return-on-effort, grounded in the STA finding:

| # | Change | Expected Fmax | Cost | Effort |
|---|--------|---------------|------|--------|
| 1 | **Register the input** (drop the combinational last-byte issue) | ~55 MHz | +1 cycle latency; lose `II==bytes` | small wrapper change |
| 2 | **Leading-zero-count tree** in `fp8_normalize` (replace the linear MSB scan) | + | none (same latency/area) | localized RTL |
| 3 | **Higher PnR effort / fix slew** (742 max-slew nets) | + | none | flow config |
| 4 | **Pipeline the C0 stage** (split the combinational datapath) | ~2× | +flops/area, +1 cycle | moderate RTL |

**#1 is the headline:** the critical path *starts at a pin*, so registering the
I/O removes ~5 ns (external delay) + ~4 ns (issue muxing) ≈ **9 ns** from a
~27 ns path → **~18 ns → Fmax ≈ 55 MHz** — small wrapper change, no touch to the
arithmetic. The textbook "register your I/O" fix, and STA points straight at it.

```
baseline (merged C0)  →  +register I/O  →  +LZC tree  →  +pipeline C0
   24 MHz                  ~55 MHz          higher        ~2× (more area)
```

## 5. Why the chip ships as-is

The taped-out FP8 targets **10 MHz** and closes it with **+47 ns** setup margin.
The design was deliberately optimised for **area** (the 4→3 stage merge, 440→161
flops), which is exactly what makes C0 combinationally long — a conscious
area-vs-speed trade. None of the optimisations above are needed for the current
target; they are the roadmap for a higher-frequency or transprecision successor.

*Data sources: `flow/reports/` (collect_metrics + sweep),
`runs/wokwi/55-openroad-stapostpnr/.../checks.rpt`.*
