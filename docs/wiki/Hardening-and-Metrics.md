# Hardening

The RTL→GDS flow, and where its outputs go.

This page used to hold both the toolchain setup and the results; both moved, to
stop three pages drifting apart:

- **Setting up Docker, LibreLane and the PDK** → [End-to-End Setup](End-to-End-Setup)
- **Area, timing and power numbers** → [Results & Metrics](Results-and-Metrics)
- **Reproducing those numbers step by step** → [Area Runbook](Area-Runbook)
- **Frequency ceiling and how to raise it** → [Timing Study](Timing-Study)

## Running it

```sh
source ~/.venvs/fp8/bin/activate
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A LIBRELANE_TAG=3.0.3

./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden
./tt/tt_tool.py --print-warnings
./tt/tt_tool.py --print-stats
```

## Where the results land

Everything under `runs/wokwi/` (git-ignored):

| What | Path |
|---|---|
| Final GDS | `runs/wokwi/final/gds/` |
| Post-PnR netlist | `runs/wokwi/final/pnl/tt_um_fp8_fpu.pnl.v` |
| Verilog lint | `runs/wokwi/*-verilator-lint/verilator-lint.log` |
| STA and `metrics.json` | the `*-openroad-*sta*` step folders |
| Detailed-routing log | `runs/wokwi/*-openroad-detailedrouting/*.log` |

Tabulate a run:

```sh
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8
```

## Reading the routing log

The one line that decides whether a run is usable:

```sh
grep -E "Number of violations" runs/wokwi/*detailedrouting/*.log | tail -3
```

It must end at **`Number of violations = 0`**. If the count falls for several
iterations and then jumps back up, the design is congested and will not
converge — stop the run rather than waiting. Violations dominated by `Short` on
met1/met2 mean local density, not total area; the lever is
`PL_TARGET_DENSITY_PCT`, not shrinking logic. See
[Design Decisions](Design-Decisions).
