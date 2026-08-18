# End-to-end setup (WSL2) — simulation → verification → LibreLane → metrics

> **Local notes** — this file is git-ignored (see `.gitignore`); it's your
> personal end-to-end reference. The published version of this content lives in
> the wiki: `docs/wiki/Getting-Started.md` (+ `Hardening-and-Metrics.md`).

Single guide to bring up the **whole** flow of this project inside **one Linux
environment (WSL2 Ubuntu)**: simulation (cocotb/Icarus), the verification tracks
(`verification/`: formal, UVM, DFT), the RTL→GDS hardening (LibreLane) and the
**metrics extraction** (area, timing/Fmax, power) for characterisation —
designed to produce reproducible numbers for a PhD.

> **Why everything on WSL2 and not native Windows?** LibreLane only runs on
> Linux+Docker anyway. Keeping **one** Linux toolchain eliminates
> "works-on-my-machine" issues and is **exactly** what the CI
> (`.github/workflows`) runs. You edit in VS Code (Windows) connected to WSL via
> Remote-WSL — the experience is identical to native.

---

## Mental map for people coming from Quartus

| Stage | Quartus (FPGA) | Here (ASIC sky130, open-source) |
|-------|----------------|----------------------------------|
| Simulation | ModelSim/Questa | **Icarus Verilog + cocotb** (Python) |
| Synthesis | Analysis & Synthesis | **Yosys** |
| Place & Route | Fitter | **OpenROAD** (floorplan/place/CTS/route) |
| Timing (STA) | TimeQuest | **OpenSTA** (same *slack* concept) |
| Physical sign-off | — | **Magic/KLayout** (GDS, DRC, LVS) |
| Orchestrator | Quartus GUI | **LibreLane** (`tt_tool.py --harden`) |
| Output | bitstream `.sof` | **GDSII** (`.gds`) |

There is also an **FPGA prototype** path (`.github/workflows/fpga.yaml`) targeting
a **Lattice iCE40UP5K** with open-source tools (Yosys + nextpnr) — useful if you
want to validate on programmable silicon first.

---

## 1. WSL2 + Ubuntu

In **PowerShell as Administrator**:

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot, open "Ubuntu", create your user/password. Confirm it is WSL **2**:

```powershell
wsl -l -v
```

> Use **Ubuntu 24.04**: it ships a newer `yosys` in apt (22.04's 0.9 is too old
> for the SVA assertions of the formal track).

## 2. VS Code connected to WSL

Install VS Code on Windows + the **WSL** (Remote - WSL) extension. Inside Ubuntu,
in the project folder, run `code .` — VS Code opens "attached" to Linux.

## 3. Clone the project INSIDE WSL

Work in the Linux home (`~`), **not** in `/mnt/c/...` (slow, Docker permission
problems):

```sh
cd ~
git clone https://github.com/raphaelPinheiro26/tt_um_fp8_fpu.git
cd tt_um_fp8_fpu
```

## 4. Base toolchain (simulation + UVM + DFT)

```sh
sudo apt update
sudo apt install -y iverilog gtkwave verilator make git python3 python3-pip python3-venv

python3 -m venv ~/.venvs/fp8
source ~/.venvs/fp8/bin/activate

pip install -r test/requirements.txt              # cocotb, pytest
pip install -r verification/uvm/requirements.txt  # cocotb, pyuvm
```

Confirm:

```sh
iverilog -V | head -1
python3 -c "import cocotb, pyuvm; print('cocotb', cocotb.__version__, '| pyuvm', pyuvm.__version__)"
```

## 5. Run the simulations

```sh
cd test && make -B          # official suite; expect: TESTS=6 PASS=6 FAIL=0
cd ..

cd sim/cocotb/pipeline && make      # block tests: also unit, handshake, controller
cd ../../..

cd verification/uvm/pyuvm
make                        # Fp8SmokeTest (fast)
make TEST=Fp8FullRandomTest # all 14 opcodes
cd ../../..

cd verification/dft
iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb   # DFT scan demo
cd ../..
```

Waveforms: the tests produce `.fst`/`.vcd`; open with `gtkwave file.fst`.

## 6. Formal verification (Yosys + SymbiYosys)

Install the **OSS CAD Suite for Linux** (the Linux bundle is solid — the Windows
one is the problematic one):

```sh
cd ~
# DOWNLOAD the newest linux-x64 .tgz from the Releases page FIRST:
#   https://github.com/YosysHQ/oss-cad-suite-build/releases
wget https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2025-08-01/oss-cad-suite-linux-x64-20250801.tgz
tar xzf oss-cad-suite-linux-x64-*.tgz
source ~/oss-cad-suite/environment     # run every formal session

cd ~/tt_um_fp8_fpu/verification/formal
./run.sh                    # runs every proof (.sby)
```

> The `tar: Cannot open: No such file or directory` error just means `tar` was
> run **before** the download finished. Do the `wget` first.

## 7. RTL→GDS hardening (LibreLane) + Docker

The "Fitter + TimeQuest + GDS" part. Tools run inside **Docker containers** that
LibreLane pulls for you. Reserve **10–15 GB** of disk; the first run downloads
the PDK + images.

### 7.1 Install the Docker Engine inside WSL (no Docker Desktop)

```sh
sudo apt update && sudo apt install -y docker.io
sudo usermod -aG docker $USER            # re-open the shell afterwards
```

Start the service — pick one:

- **systemd (stays on):** put `[boot]` / `systemd=true` in `/etc/wsl.conf`, run
  `wsl --shutdown` in PowerShell, reopen Ubuntu, then
  `sudo systemctl enable --now docker`.
- **manual (per session):** `sudo service docker start`.

Verify: `docker run --rm hello-world` → "Hello from Docker!". Common errors:
`Cannot connect to the Docker daemon` → service not started; `permission denied …
docker.sock` → re-open the terminal after `usermod` (or `newgrp docker`).

### 7.2 tt-support-tools + LibreLane

```sh
cd ~/tt_um_fp8_fpu
git clone https://github.com/TinyTapeout/tt-support-tools tt   # already in .gitignore

source ~/.venvs/fp8/bin/activate
pip install -r tt/requirements.txt

export PDK_ROOT=~/ttsetup/pdk           # keep these 3 exports for every new shell
export PDK=sky130A
export LIBRELANE_TAG=3.0.3
pip install librelane==$LIBRELANE_TAG
```

### 7.3 Run the hardening

```sh
./tt/tt_tool.py --create-user-config   # generates the config from info.yaml
./tt/tt_tool.py --harden               # lint → synth → floorplan → place → CTS → route → STA → GDS
./tt/tt_tool.py --print-warnings
./tt/tt_tool.py --print-stats
```

### 7.4 Where the results live

Everything lands in `runs/wokwi/` (git-ignored):

- **Final GDS:** `runs/wokwi/final/gds/`
- **Post-PnR netlist:** `runs/wokwi/final/pnl/tt_um_fp8_fpu.pnl.v`
- **Verilog lint:** `runs/wokwi/*-verilator-lint/verilator-lint.log`
- **STA / timing + `metrics.json`:** in the step folders (e.g. `*-openroad-*sta*`)

### 7.5 Gate-level test (validates the post-synthesis netlist)

```sh
cd test
TOP=$(cd .. && ./tt/tt_tool.py --print-top-module)
cp ../runs/wokwi/final/pnl/$TOP.pnl.v gate_level_netlist.v
make -B GATES=yes
cd ..
```

### 7.6 Changing the PDK (experiments only)

> ⚠️ For the TT submission the PDK is **fixed** to `sky130A` by the shuttle. The
> change below is only for your own experiments (e.g. sky130 vs gf180 in a
> thesis), running LibreLane outside the TT flow.

```sh
pip install ciel
export PDK_ROOT=~/ttsetup/pdk
ciel ls --pdk sky130                 # available versions
ciel enable --pdk gf180mcu <hash>    # download/activate a version
```

Then run `librelane config.json` with a minimal config pointing `"PDK"` at the
process you want.

## 8. Metrics for the PhD

```sh
# single-run table (area + cells + timing + power + estimated Fmax)
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8

# real Fmax (each point re-runs --harden — keep the list short)
python3 flow/sweep_clock.py --periods 40,30,25,20,16,13 --out flow/reports/sweep
```

`collect_metrics.py` merges the cumulative `metrics.json`, extracts the fields
that matter and **estimates Fmax** = 1000 / (period − setup slack) MHz.
`sweep_clock.py` varies `CLOCK_PERIOD` in `src/config.json` (backing up and
restoring the original), re-hardens at each period and reports the smallest
period that still closes timing.

> **Power:** the STA `power__total` uses default switching rates. For realistic
> dynamic power, feed a VCD/SAIF from a representative gate-level sim into STA.

---

## Command summary

| Goal | Command |
|------|---------|
| Official suite | `cd test && make -B` |
| UVM (constrained-random) | `cd verification/uvm/pyuvm && make TEST=Fp8FullRandomTest` |
| Formal | `source ~/oss-cad-suite/environment && cd verification/formal && ./run.sh` |
| DFT (scan) | `cd verification/dft && iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb` |
| Flop inventory (DFT) | `cd verification/dft && yosys scan_insert.ys` |
| RTL→GDS hardening | `./tt/tt_tool.py --harden` |
| Metrics table | `python3 flow/collect_metrics.py --out flow/reports/fp8` |
| Fmax sweep | `python3 flow/sweep_clock.py --periods 40,30,20,15` |

All of this is what the CI (`.github/workflows/{test,formal,uvm,gds}.yaml`) runs
in the cloud — locally you get the same, with fast iteration.
