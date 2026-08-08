# flow/ — hardening metrics tooling

Reproducible characterisation metrics from a LibreLane / Tiny Tapeout hardening
run: area, cell counts, timing (setup/hold slack, Fmax) and power, tabulated to
CSV/Markdown. Stdlib-only Python, no dependencies.

- `collect_metrics.py` — one-run table (merges the cumulative `metrics.json`,
  estimates `Fmax ≈ 1000 / (CLOCK_PERIOD − setup_slack)` MHz).
- `sweep_clock.py` — characterised Fmax by re-hardening across clock periods
  (backs up and restores `src/config.json`).

**Full documentation — the metrics, the Fmax methodology and the latest results
— is in the wiki:** [Hardening & Metrics](../docs/wiki/Hardening-and-Metrics.md).

```sh
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8
python3 flow/sweep_clock.py --periods 40,30,25,20,16,13 --out flow/reports/sweep
```
