#!/usr/bin/env python3
# ======================================================================
# collect_metrics.py — Extract a reproducible metrics table from a
# LibreLane / Tiny Tapeout hardening run.
#
# After `./tt/tt_tool.py --harden`, LibreLane leaves a run under runs/wokwi/
# with per-step metrics.json files (each cumulative). This script merges them,
# pulls the metrics that matter for a hardware characterisation (area, cell
# count, timing/Fmax, power), estimates Fmax from the clock period and worst
# setup slack, and writes both a human table and machine-readable CSV/Markdown
# for a thesis.
#
# Usage:
#   python3 flow/collect_metrics.py                      # defaults to runs/wokwi
#   python3 flow/collect_metrics.py --run runs/wokwi
#   python3 flow/collect_metrics.py --run runs/wokwi --clock-period 100
#   python3 flow/collect_metrics.py --out flow/reports/fp8   # -> fp8.csv/.md
#
# No third-party dependencies (stdlib only).
# ======================================================================
import argparse
import csv
import glob
import json
import os
import sys


# ----------------------------------------------------------------------
# Metric key lookup. LibreLane/OpenLane-2 keys are dotted; names drift a bit
# between versions, so each row lists candidate keys tried in order. The first
# key that exists in the merged metrics wins.
# ----------------------------------------------------------------------
METRIC_ROWS = [
    # (label, [candidate keys...], unit, fmt)
    ("Std-cell instances",   ["design__instance__count",
                              "design__instance__count__stdcell"],       "cells", "int"),
    ("Unmapped instances",   ["design__instance_unmapped__count"],        "cells", "int"),
    ("Cell area",            ["design__instance__area"],                  "um^2",  "f2"),
    ("Die area",             ["design__die__area"],                       "um^2",  "f2"),
    ("Core area",            ["design__core__area"],                      "um^2",  "f2"),
    ("Core utilization",     ["design__instance__utilization"],           "%",     "pct"),
    ("Total wirelength",     ["route__wirelength__total"],                "um",    "f2"),
    ("Setup worst slack",    ["timing__setup__ws", "timing__setup__wns"], "ns",    "f3"),
    ("Hold worst slack",     ["timing__hold__ws",  "timing__hold__wns"],  "ns",    "f3"),
    ("Setup TNS",            ["timing__setup__tns"],                      "ns",    "f3"),
    ("Clock skew (worst)",   ["clock__skew__worst"],                      "ns",    "f3"),
    ("Max slew violations",  ["design__max_slew_violation__count"],       "",      "int"),
    ("Max cap violations",   ["design__max_cap_violation__count"],        "",      "int"),
    ("Total power",          ["power__total"],                            "W",     "f4"),
    ("  dynamic (internal)", ["power__internal__total"],                  "W",     "f4"),
    ("  dynamic (switching)",["power__switching__total"],                 "W",     "f4"),
    ("  static (leakage)",   ["power__leakage__total"],                   "W",     "f4"),
    ("DRC violations",       ["magic__drc__count", "klayout__drc__count"],"",      "int"),
    ("LVS errors",           ["design__lvs__errors__count",
                              "design__lvs__error__count"],               "",      "int"),
]

# Candidate keys where the clock period may be recorded (ns).
CLOCK_KEYS = ["CLOCK_PERIOD", "clock__period", "design__clock__period"]


def merge_metrics(run_dir):
    """Merge every metrics.json under run_dir; later files (by mtime) win."""
    files = sorted(glob.glob(os.path.join(run_dir, "**", "metrics.json"),
                             recursive=True), key=os.path.getmtime)
    if not files:
        # maybe the user pointed directly at a metrics.json
        if run_dir.endswith(".json") and os.path.isfile(run_dir):
            files = [run_dir]
        else:
            return {}, []
    merged = {}
    for f in files:
        try:
            with open(f) as fh:
                merged.update(json.load(fh))
        except (json.JSONDecodeError, OSError):
            continue
    return merged, files


def find_clock_period(run_dir, merged, override):
    if override is not None:
        return float(override), "cli"
    for k in CLOCK_KEYS:
        if k in merged:
            try:
                return float(merged[k]), f"metrics[{k}]"
            except (TypeError, ValueError):
                pass
    # fall back to resolved.json / config.json in the run
    for cand in ("resolved.json", "config.json"):
        for path in glob.glob(os.path.join(run_dir, "**", cand), recursive=True):
            try:
                with open(path) as fh:
                    cfg = json.load(fh)
                if "CLOCK_PERIOD" in cfg:
                    return float(cfg["CLOCK_PERIOD"]), os.path.relpath(path, run_dir)
            except (json.JSONDecodeError, OSError, TypeError, ValueError):
                continue
    return None, None


def first_present(merged, keys):
    for k in keys:
        if k in merged and merged[k] is not None:
            return merged[k], k
    return None, None


def fmt_value(val, fmt):
    if val is None:
        return "n/a"
    try:
        if fmt == "int":
            return f"{int(round(float(val)))}"
        if fmt == "pct":
            v = float(val)
            return f"{v*100:.1f}" if v <= 1.0 else f"{v:.1f}"
        if fmt == "f2":
            return f"{float(val):.2f}"
        if fmt == "f3":
            return f"{float(val):.3f}"
        if fmt == "f4":
            return f"{float(val):.4f}"
    except (TypeError, ValueError):
        return str(val)
    return str(val)


def main():
    ap = argparse.ArgumentParser(description="Tabulate LibreLane hardening metrics.")
    ap.add_argument("--run", default="runs/wokwi",
                    help="LibreLane run directory (or a metrics.json). Default: runs/wokwi")
    ap.add_argument("--clock-period", type=float, default=None,
                    help="Override clock period (ns) used for the Fmax estimate.")
    ap.add_argument("--out", default=None,
                    help="Output path prefix; writes <prefix>.csv and <prefix>.md")
    args = ap.parse_args()

    merged, files = merge_metrics(args.run)
    if not merged:
        sys.exit(f"ERROR: no metrics.json found under '{args.run}'. "
                 f"Run `./tt/tt_tool.py --harden` first.")

    rows = []           # (label, value_str, unit, raw, key)
    for label, keys, unit, fmt in METRIC_ROWS:
        raw, key = first_present(merged, keys)
        rows.append((label, fmt_value(raw, fmt), unit, raw, key))

    # ---- Fmax estimate from clock period + worst setup slack ----
    period, period_src = find_clock_period(args.run, merged, args.clock_period)
    ws_setup, _ = first_present(merged, ["timing__setup__ws", "timing__setup__wns"])
    fmax_row = None
    if period and ws_setup is not None:
        try:
            crit = period - float(ws_setup)       # critical-path delay (ns)
            if crit > 0:
                fmax = 1000.0 / crit              # MHz
                fmax_row = (period, float(ws_setup), crit, fmax, period_src)
        except (TypeError, ValueError):
            pass

    # ---- print ----
    print(f"\nLibreLane run : {args.run}")
    print(f"metrics files : {len(files)} merged")
    w = max(len(r[0]) for r in rows) + 2
    print("-" * (w + 22))
    for label, vstr, unit, raw, key in rows:
        print(f"{label:<{w}} {vstr:>12} {unit}")
    print("-" * (w + 22))
    if fmax_row:
        period, ws, crit, fmax, src = fmax_row
        print(f"{'Clock period (T)':<{w}} {period:>12.3f} ns   (from {src})")
        print(f"{'Critical path (T - slack)':<{w}} {crit:>12.3f} ns")
        print(f"{'Estimated Fmax':<{w}} {fmax:>12.2f} MHz")
        print("-" * (w + 22))
        print("Note: Fmax is a single-run estimate. Use flow/sweep_clock.py to")
        print("confirm the true maximum by sweeping CLOCK_PERIOD.")
    else:
        print("Fmax: not computed (missing clock period or setup slack).")

    # ---- write files ----
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        csv_path, md_path = args.out + ".csv", args.out + ".md"
        with open(csv_path, "w", newline="") as fh:
            wtr = csv.writer(fh)
            wtr.writerow(["metric", "value", "unit", "raw", "librelane_key"])
            for label, vstr, unit, raw, key in rows:
                wtr.writerow([label.strip(), vstr, unit, raw, key or ""])
            if fmax_row:
                p, ws, crit, fmax, src = fmax_row
                wtr.writerow(["Clock period", f"{p:.3f}", "ns", p, src])
                wtr.writerow(["Estimated Fmax", f"{fmax:.2f}", "MHz", fmax, "derived"])
        with open(md_path, "w") as fh:
            fh.write("| Metric | Value | Unit |\n|---|---:|---|\n")
            for label, vstr, unit, raw, key in rows:
                fh.write(f"| {label.strip()} | {vstr} | {unit} |\n")
            if fmax_row:
                p, ws, crit, fmax, src = fmax_row
                fh.write(f"| Clock period | {p:.3f} | ns |\n")
                fh.write(f"| **Estimated Fmax** | **{fmax:.2f}** | MHz |\n")
        print(f"\nWrote {csv_path} and {md_path}")


if __name__ == "__main__":
    main()
