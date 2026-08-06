#!/usr/bin/env python3
# ======================================================================
# sweep_clock.py — Find the true Fmax by sweeping CLOCK_PERIOD through the
# LibreLane hardening flow and recording setup/hold slack at each point.
#
# collect_metrics.py estimates Fmax from a SINGLE run (period - worst slack).
# That is a good first guess, but resizing/CTS behaviour changes with the
# target period, so the honest number comes from re-hardening at several
# periods and taking the fastest one that still closes timing. This script
# automates that loop — useful for a characterisation table in a thesis.
#
# WARNING: each point re-runs `--harden` (minutes each). Keep the list short.
#
# Usage (from the repo root, inside the activated tt venv, Docker running):
#   python3 flow/sweep_clock.py --periods 40,30,25,20,16,13
#   python3 flow/sweep_clock.py --periods 20,15,12 --out flow/reports/sweep
#
# It edits src/config.json's CLOCK_PERIOD in place for each point and ALWAYS
# restores the original afterwards (even on Ctrl-C / crash).
# ======================================================================
import argparse
import csv
import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from collect_metrics import merge_metrics, first_present   # noqa: E402


def read_slacks(run_dir):
    merged, _ = merge_metrics(run_dir)
    ws, _ = first_present(merged, ["timing__setup__ws", "timing__setup__wns"])
    wh, _ = first_present(merged, ["timing__hold__ws", "timing__hold__wns"])
    cells, _ = first_present(merged, ["design__instance__count"])
    area, _ = first_present(merged, ["design__instance__area"])
    power, _ = first_present(merged, ["power__total"])
    def f(x):
        try:
            return float(x)
        except (TypeError, ValueError):
            return None
    return f(ws), f(wh), f(cells), f(area), f(power)


def set_clock_period(config_path, period):
    with open(config_path) as fh:
        cfg = json.load(fh)
    cfg["CLOCK_PERIOD"] = period
    with open(config_path, "w") as fh:
        json.dump(cfg, fh, indent=2)


def main():
    ap = argparse.ArgumentParser(description="Sweep CLOCK_PERIOD to find Fmax.")
    ap.add_argument("--periods", required=True,
                    help="Comma-separated clock periods in ns, e.g. 40,30,25,20")
    ap.add_argument("--config", default="src/config.json",
                    help="Path to the LibreLane config with CLOCK_PERIOD.")
    ap.add_argument("--tt", default="./tt/tt_tool.py",
                    help="Path to tt_tool.py (the harden driver).")
    ap.add_argument("--run", default="runs/wokwi", help="Run dir to read metrics from.")
    ap.add_argument("--out", default=None, help="CSV output path prefix.")
    ap.add_argument("--dry-run", action="store_true",
                    help="Print the plan without running the flow.")
    args = ap.parse_args()

    periods = [float(p) for p in args.periods.split(",") if p.strip()]
    if not os.path.isfile(args.config):
        sys.exit(f"config not found: {args.config}")

    with open(args.config) as fh:
        original = fh.read()

    results = []
    try:
        for T in periods:
            print(f"\n===== CLOCK_PERIOD = {T} ns "
                  f"({1000.0/T:.1f} MHz target) =====")
            if args.dry_run:
                results.append((T, None, None, None, None, None, "dry-run"))
                continue
            set_clock_period(args.config, T)
            rc = subprocess.call([sys.executable, args.tt, "--harden"])
            ws, wh, cells, area, power = read_slacks(args.run)
            met = "?" if (ws is None or wh is None) else \
                  ("YES" if (ws >= 0 and wh >= 0) else "no")
            status = "ok" if rc == 0 else f"harden rc={rc}"
            results.append((T, ws, wh, cells, area, power, f"{met}/{status}"))
            print(f"  setup_ws={ws} hold_ws={wh} meets_timing={met} ({status})")
    finally:
        with open(args.config, "w") as fh:
            fh.write(original)
        print(f"\nrestored original {args.config}")

    # ---- report ----
    print("\n" + "=" * 78)
    print(f"{'T(ns)':>7} {'Ftarget':>8} {'setup_ws':>9} {'hold_ws':>8} "
          f"{'cells':>6} {'area(um2)':>10} {'power(W)':>10} {'meets':>10}")
    print("-" * 78)
    best_T = None
    for T, ws, wh, cells, area, power, meet in results:
        ft = f"{1000.0/T:.1f}"
        print(f"{T:>7.2f} {ft:>8} "
              f"{('%.3f'%ws) if ws is not None else 'n/a':>9} "
              f"{('%.3f'%wh) if wh is not None else 'n/a':>8} "
              f"{('%d'%cells) if cells else 'n/a':>6} "
              f"{('%.1f'%area) if area else 'n/a':>10} "
              f"{('%.5f'%power) if power else 'n/a':>10} {meet:>10}")
        if ws is not None and wh is not None and ws >= 0 and wh >= 0:
            if best_T is None or T < best_T:
                best_T = T
    print("=" * 78)
    if best_T:
        print(f"Fastest period that closes timing: {best_T:.2f} ns "
              f"-> Fmax ~= {1000.0/best_T:.2f} MHz")
        print("(Refine by sweeping finer periods just below the failing point.)")
    else:
        print("No swept period closed timing (or metrics unreadable).")

    if args.out and not args.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        with open(args.out + ".csv", "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(["period_ns", "f_target_mhz", "setup_ws_ns", "hold_ws_ns",
                        "cells", "cell_area_um2", "power_w", "meets_timing"])
            for T, ws, wh, cells, area, power, meet in results:
                w.writerow([T, f"{1000.0/T:.3f}", ws, wh, cells, area, power, meet])
        print(f"Wrote {args.out}.csv")


if __name__ == "__main__":
    main()
