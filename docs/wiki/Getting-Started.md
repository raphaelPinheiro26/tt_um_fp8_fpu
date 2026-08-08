# Getting Started

The whole flow runs inside a single **WSL2 Ubuntu** environment (edit from VS
Code via Remote-WSL). This page is self-contained.

> **Why WSL2 and not native Windows?** LibreLane only runs on Linux+Docker, and a
> single Linux toolchain matches exactly what the CI (`.github/workflows`) runs —
> no "works-on-my-machine". You edit in VS Code (Windows) attached to WSL, so it
> feels native. (Native-Windows simulation was tried and dropped — WSL2 is the
> supported path.)

## Coming from Quartus?

| Stage | Quartus (FPGA) | Here (ASIC sky130, open-source) |
|-------|----------------|----------------------------------|
| Simulation | ModelSim/Questa | Icarus Verilog + cocotb (Python) |
| Synthesis | Analysis & Synthesis | Yosys |
| Place & Route | Fitter | OpenROAD |
| Timing (STA) | TimeQuest | OpenSTA (same *slack* concept) |
| Physical sign-off | — | Magic/KLayout (GDS, DRC, LVS) |
| Orchestrator | Quartus GUI | LibreLane (`tt_tool.py --harden`) |
| Output | bitstream `.sof` | GDSII (`.gds`) |

## 1. WSL2 + tools

```sh
# in PowerShell (admin): wsl --install -d Ubuntu-24.04
#   (Ubuntu 24.04 ships a newer apt yosys — needed for the formal track)
sudo apt update
sudo apt install -y iverilog gtkwave verilator make git python3 python3-pip python3-venv
python3 -m venv ~/.venvs/fp8 && source ~/.venvs/fp8/bin/activate
pip install cocotb pytest pyuvm
```

Install the **WSL** (Remote - WSL) extension in VS Code; from the project folder
inside Ubuntu run `code .` to open VS Code attached to Linux.

## 2. Clone and simulate

Work in the Linux home (`~`), **not** in `/mnt/c/...` (slow, and Docker
permission issues):

```sh
cd ~
git clone https://github.com/<user>/tt_um_fp8_fpu.git
cd tt_um_fp8_fpu
cd test && make -B            # expect: TESTS=6 PASS=6 FAIL=0
cd ..
```

Block-level cocotb tests live under `sim/cocotb/` (`pipeline`, `unit`,
`handshake`, `controller`):

```sh
cd sim/cocotb/pipeline && make      # golden-vector replay + back-pressure
cd ../../..
```

## 3. The rest of the flow

| Goal | Command | Page |
|------|---------|------|
| UVM (constrained-random) | `cd verification/uvm/pyuvm && make TEST=Fp8FullRandomTest` | [Verification-UVM](Verification-UVM) |
| Formal | `source ~/oss-cad-suite/environment && cd verification/formal && ./run.sh` | [Verification-Formal](Verification-Formal) |
| DFT scan demo | `cd verification/dft && iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb` | [Verification-DFT](Verification-DFT) |
| Hardening (GDS) | `./tt/tt_tool.py --harden` | [Hardening & Metrics](Hardening-and-Metrics) |

## 4. Formal — one extra install

Formal needs a recent Yosys + `sby` + a solver. The apt `yosys` on older Ubuntu
is too old, so install the **OSS CAD Suite (Linux)** inside WSL:

```sh
cd ~
# download the newest Linux x64 asset from the Releases page FIRST, then:
#   https://github.com/YosysHQ/oss-cad-suite-build/releases
tar xzf oss-cad-suite-linux-x64-*.tgz
source ~/oss-cad-suite/environment     # run each formal session
cd ~/tt_um_fp8_fpu/verification/formal && ./run.sh
```

More on [Verification-Formal](Verification-Formal).

## 5. Hardening — needs Docker

Hardening (RTL→GDS) runs inside Docker. Full step-by-step (Docker Engine in WSL,
tt-support-tools, LibreLane, results locations) is on
[Hardening & Metrics](Hardening-and-Metrics). The short version:

```sh
git clone https://github.com/TinyTapeout/tt-support-tools tt
source ~/.venvs/fp8/bin/activate && pip install -r tt/requirements.txt
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A LIBRELANE_TAG=3.0.3
pip install librelane==$LIBRELANE_TAG
./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden && ./tt/tt_tool.py --print-stats
```

## Notes

- For the full command reference and the flow order, see
  [Tools Cheatsheet](Tools-Cheatsheet).
- Everything here is what the CI
  (`.github/workflows/{test,formal,uvm,gds}.yaml`) runs in the cloud — locally
  you get the same, with fast iteration.
