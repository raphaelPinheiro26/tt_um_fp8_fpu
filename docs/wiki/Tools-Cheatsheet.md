# Tools Cheatsheet

The tools are **quality gates**, not a single pipeline — most start from the same
RTL. Natural order: **simulate → lint → formal → (UVM in parallel) → harden →
metrics**. Setup detail: [Getting Started](Getting-Started); hardening detail:
[Hardening & Metrics](Hardening-and-Metrics).

| # | Stage | Question it answers | Tool |
|---|-------|---------------------|------|
| 1 | Functional sim | Does it compute the right value? | iverilog + cocotb |
| 2 | Lint | Width mistakes, undriven nets? | Verilator |
| 3 | Formal | Property true for *all* states? | Yosys + SymbiYosys |
| 4 | UVM | Random + self-check vs model | pyuvm + cocotb |
| 5 | Hardening | Layout? Timing? Area/power? | LibreLane |
| 6 | DFT | Testable at the fab? | Yosys / Fault |
| 7 | Metrics | Numbers for characterisation | `flow/` scripts |

## One-liners

```sh
# functional sim (official suite)
cd test && make -B

# lint
verilator --lint-only -Wall -I src src/tt_um_fp8_fpu.v

# formal (after: source ~/oss-cad-suite/environment)
cd verification/formal && ./run.sh

# UVM constrained-random
cd verification/uvm/pyuvm && make TEST=Fp8FullRandomTest

# DFT flop inventory / scan demo
cd verification/dft && yosys scan_insert.ys

# waveforms
gtkwave test/tb.fst

# hardening (needs Docker)
./tt/tt_tool.py --harden && ./tt/tt_tool.py --print-stats

# metrics table
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8
```

## SystemVerilog testbenches?

- **iverilog `-g2012`** runs a large SV subset (initial/always, `logic`, structs,
  immediate asserts, `$display`). Verilog design + SV TB compile together fine.
- **Verilator** — strong SV, but cycle-based 2-state: no `#` delays; used for lint
  and fast sim with a cocotb/C++ harness.
- **Full UVM** needs a commercial simulator → that's why this project uses
  **pyuvm** (UVM in Python on iverilog).

## Changing PDK

`PDK=sky130A` for Tiny Tapeout (fixed by the shuttle). For your own experiments
(e.g. sky130 vs `gf180mcuD` in a thesis), run LibreLane standalone with a custom
config — see [Hardening & Metrics §6](Hardening-and-Metrics).
