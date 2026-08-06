# flow/ — hardening metrics tooling

Reproducible characterisation metrics from a LibreLane / Tiny Tapeout hardening
run: area, standard-cell count, timing (setup/hold slack, Fmax) and power,
tabulated to CSV/Markdown for a report or thesis. Stdlib-only Python, no deps.

See the end-to-end setup in
[`../docs/SETUP_END_TO_END.md`](../docs/SETUP_END_TO_END.md).

## Scripts

### `collect_metrics.py` — one-run table

```bash
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8
```

Merges every cumulative `metrics.json` under the run (later steps win), pulls a
curated set of metrics, estimates Fmax, and writes `<out>.csv` + `<out>.md`.

**Fmax estimate:** `Fmax ≈ 1000 / (CLOCK_PERIOD − setup_worst_slack)` MHz. With
large positive slack (the taped-out config declares a slow 100 ns / 10 MHz
clock) this shows how much headroom the design has. It is a *single-run*
estimate — resizing/CTS decisions change with the target period, so confirm
with the sweep below.

### `sweep_clock.py` — characterised Fmax

```bash
python3 flow/sweep_clock.py --periods 40,30,25,20,16,13 --out flow/reports/sweep
python3 flow/sweep_clock.py --periods 40,20,13 --dry-run   # plan only, no run
```

Re-hardens at each `CLOCK_PERIOD` (editing `src/config.json`, always restoring
it), records setup/hold slack, cells, area and power per point, and reports the
fastest period that still closes timing → the characterised Fmax. Each point is
a full `--harden` (minutes), so keep the list short and refine around the knee.

## Metric keys

LibreLane/OpenLane-2 writes dotted keys in `metrics.json`. Names drift between
versions, so `collect_metrics.py` tries candidates in order. The main ones:

| Reported as | `metrics.json` key |
|-------------|--------------------|
| Std-cell instances | `design__instance__count` |
| Cell / die / core area | `design__instance__area`, `design__die__area`, `design__core__area` |
| Core utilization | `design__instance__utilization` |
| Setup / hold worst slack | `timing__setup__ws`, `timing__hold__ws` |
| Setup TNS | `timing__setup__tns` |
| Clock skew | `clock__skew__worst` |
| Power (total / int / sw / leak) | `power__total`, `power__internal__total`, `power__switching__total`, `power__leakage__total` |
| DRC / LVS | `magic__drc__count`, `design__lvs__errors__count` |

If your LibreLane version renames one, add its key to the candidate list in
`METRIC_ROWS` inside `collect_metrics.py`.

## Activity-based (realistic dynamic) power

By default OpenSTA `report_power` assumes a fixed toggle rate, so
`power__switching__total` is a rough figure. For thesis-grade dynamic power,
drive it with real switching activity:

1. Run a representative **gate-level** simulation and dump a VCD (harden first,
   then the gate-level cocotb flow in `../docs/LIBRELANE_LOCAL_WINDOWS.md#9`,
   with waveform dumping enabled).
2. Feed that VCD to OpenSTA (`read_vcd`/`set_power_activity`) in a custom STA
   script, or convert it to SAIF. The resulting `power__*` numbers then reflect
   the actual operation mix (e.g. a stream of DIV vs ADD ops).
3. Re-run `collect_metrics.py` to pick up the updated values.

State the activity source (default vs VCD-driven, and which stimulus) alongside
any power number you report — it materially changes dynamic power.

## Output

`flow/reports/` holds generated CSV/MD (git-ignored). Commit a snapshot only if
you want a specific run's numbers versioned with the thesis.
