# Hardening & Metrics

Turning RTL into a physical layout (GDSII) and measuring it. The tools (Yosys,
OpenROAD, OpenSTA…) run inside **Docker** via **LibreLane**; the Tiny Tapeout
`tt_tool.py` wraps the config. This mirrors exactly what the `gds.yaml` CI
workflow runs (LibreLane 3.0.3, PDK sky130A, shuttle ttsky26c).

> Reserve **10–15 GB** of disk and a good connection: the first run downloads the
> sky130 PDK (a few GB) and Docker images; later runs reuse them and are fast.

## 1. Docker Engine in WSL (no Docker Desktop)

LibreLane needs Docker. Install it directly in the WSL Ubuntu:

```sh
sudo apt update && sudo apt install -y docker.io
sudo usermod -aG docker $USER          # run without sudo (re-open the shell after)
```

Start the service — pick one:

- **systemd (stays on):** put `[boot]\nsystemd=true` in `/etc/wsl.conf`, run
  `wsl --shutdown` in PowerShell, reopen Ubuntu, then
  `sudo systemctl enable --now docker`.
- **manual (per session):** `sudo service docker start`.

Verify: `docker run --rm hello-world` prints "Hello from Docker!". Common errors:
`Cannot connect to the Docker daemon` → service not started; `permission denied
… docker.sock` → re-open the terminal after `usermod` (or `newgrp docker`).

## 2. tt-support-tools + LibreLane

```sh
cd ~/tt_um_fp8_fpu
git clone https://github.com/TinyTapeout/tt-support-tools tt   # already in .gitignore
source ~/.venvs/fp8/bin/activate
pip install -r tt/requirements.txt
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A LIBRELANE_TAG=3.0.3   # needed every new shell
pip install librelane==$LIBRELANE_TAG
```

## 3. Run the hardening

```sh
./tt/tt_tool.py --create-user-config   # generates the config from info.yaml
./tt/tt_tool.py --harden               # lint → synth → floorplan → place → CTS → route → STA → GDS
./tt/tt_tool.py --print-warnings
./tt/tt_tool.py --print-stats
```

`--harden` runs Verilator lint, Yosys synthesis, OpenROAD PnR and OpenSTA timing;
it complains here if the Verilog won't compile or misses timing. Outputs in
`runs/wokwi/` (git-ignored): GDS `final/gds/`, netlist
`final/pnl/tt_um_fp8_fpu.pnl.v`, lint `*-verilator-lint/verilator-lint.log`,
timing + `metrics.json` in the step folders. View the layout with
`--open-in-openroad` / `--open-in-klayout` (run `xhost +local:docker` first if
the display errors).

Gate-level test against the synthesised netlist:

```sh
cd test
TOP=$(cd .. && ./tt/tt_tool.py --print-top-module)
cp ../runs/wokwi/final/pnl/$TOP.pnl.v gate_level_netlist.v
make -B GATES=yes
```

## 4. Metrics tooling

```sh
# tabulate one run (area, cells, timing, power, estimated Fmax)
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8

# characterise Fmax by sweeping the clock period
python3 flow/sweep_clock.py --periods 40,30,25,20,16,13 --out flow/reports/sweep
```

`Fmax ≈ 1000 / (CLOCK_PERIOD − setup_worst_slack)` MHz from a single run; the
sweep confirms the true maximum by re-hardening at several periods. See
[`flow/README.md`](../../flow/README.md). For realistic dynamic power, feed a
VCD/SAIF from a gate-level sim into STA (the default `power__total` uses default
switching activity).

## 5. Results (latest sky130 run, CLOCK_PERIOD = 100 ns)

| Metric | Value |
|--------|------:|
| Process / PDK | sky130A (1.8 V) |
| Tiles | 1×2 |
| Logic cells (excl. fill/tap) | 2 396 |
| Total cells (incl. fill/tap) | 5 470 |
| Flip-flops (`dfrtp`) | 227 |
| Multiplexers | 257 |
| Core utilization | 72.4 % |
| Wire length (µm) | 89 432 |
| **TT precheck** | 15 / 15 ✅ |
| **Gate-level tests** | 6 / 6 passed |

Cell mix: 648 combinational, 257 mux, 227 NOR/XNOR, 227 flip-flops, 195 OR/XOR,
164 NAND, 148 clock, 131 AND, 81 buffer, 59 inverter, 30 diode, 229 misc.

Timing, power and Fmax characterisation (from the earlier clock-sweep run, which
predates this netlist) is on the [Timing Study](Timing-Study) page: as-is
**≈ 24 MHz**, ceiling **≈ 40 MHz**, with the critical path pinned to the
combinational C0 stage and a clear "register the I/O" optimisation roadmap.

## 6. Changing PDK (experiments)

For the TT submission the PDK is **fixed** to `sky130A` by the shuttle. For your
own characterisation (e.g. sky130 vs `gf180mcuD` in a thesis), run LibreLane
standalone — the PDK is selected by the `PDK` env var and downloaded to
`PDK_ROOT` by `ciel`:

```sh
pip install ciel
export PDK_ROOT=~/ttsetup/pdk
ciel ls --pdk sky130                 # available versions
ciel enable --pdk gf180mcu <hash>    # download/activate a version
```

Run LibreLane directly (outside `tt_tool.py`) with a minimal config
(`{"DESIGN_NAME":"tt_um_fp8_fpu","VERILOG_FILES":["dir::src/*.v"],"CLOCK_PORT":"clk","CLOCK_PERIOD":20,"PDK":"gf180mcuD"}`)
via `librelane config.json`. A side-by-side PDK comparison of the same RTL is a
strong thesis result.
