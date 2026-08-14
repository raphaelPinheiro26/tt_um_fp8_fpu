# Area runbook — measure the narrowed datapath and size what fits next

Focused procedure to (a) prove the narrowed datapath is still correct, (b) get
the real sky130 area/timing numbers, and (c) decide how much of CVT/FMA fits in
the remaining budget.

Toolchain setup is **not** repeated here — see `SETUP_END_TO_END.md` (local) or
`docs/wiki/Getting-Started.md`. This assumes WSL2 with the venv, Docker and
LibreLane already working.

Everything below should be run from a Linux checkout (`~/tt_um_fp8_fpu`), not
from `/mnt/c/...`.

---

## 0. What changed, and the numbers to beat

| Parameter | Before | Now | Where |
|---|---:|---:|---|
| `NRM_G` | 20 | 4 | `src/header_fp8.v` |
| `NRM_ACCW` | 26 | 10 | idem |
| `NRM_MW` | 16 (hardcoded) | 8 | idem |

Reference point — the last hardening run before these changes:

| Metric | Value |
|---|---|
| Core utilisation | **72.429 %** |
| Cells (excl. fill/tap) | **2396** |
| Flip-flops (`dfrtp`) | **227** |
| Wire length | 89 432 µm |
| Fill / decap | 2618 |
| Tiles | 1×2 |

Predicted after the change (yosys generic-gate scaling, **not** authoritative):
≈ **−520 cells**, landing near **1876 cells / ~57 % utilisation**. Step 3 is what
replaces this estimate with a real number.

---

## 1. Regression first — do not harden untested RTL

```sh
cd ~/tt_um_fp8_fpu

# regenerate both vector sets if you do not have them.
# NOTE: --new writes vectors_newops.hex, the default writes vectors.hex.
# They are two different files — do not send both to the same one.
cd Golden_model
python3 gen_vectors_math.py                              # 1,311,488 -> vectors.hex
python3 gen_vectors_math.py --new                        #   527,360 -> vectors_newops.hex
wc -l vectors.hex vectors_newops.hex                     # expect 1311488 and 527360
cd ..

cd test
chmod +x regress.sh             
JOBS=$(nproc) ./regress.sh             # all 14 opcodes, ~1.84M vectors
cd ..
```

Expected last line: `ALL PASS`. Anything else — stop, do not proceed. The log of
a failing opcode is at `/tmp/fp8_regress/log_<op>.txt` and the first mismatch is
printed with the operation index.

Reference runtime: a few hours on 8 cores. `JOBS=$(nproc) ./regress.sh add sub
mult div` first if you want the arithmetic core covered quickly.

---

## 2. Quick area sanity check (optional, seconds)

Technology-independent gate count, useful to confirm you are building what you
think you are building:

```sh
cd ~/tt_um_fp8_fpu
cat > /tmp/area.ys <<'EOF'
read_verilog -I src src/tt_um_fp8_fpu.v src/tiny_fp8_unit.v src/fp8_controller.v \
  src/fp8_elastic_pipeline.v src/fp8_handshake_reg.v src/fp8_pre_execute.v \
  src/fp8_unpack.v src/fp8_execute_comb.v src/fp8_normalize.v src/fp8_round.v \
  src/fp8_div_iter.v src/fp8_direct_ops.v
hierarchy -top tt_um_fp8_fpu
proc; flatten; opt -full
techmap; opt -full
stat
EOF
yosys -s /tmp/area.ys | tail -20
```

Expect ≈ **4079 cells / 248 DFF**. Before the change it was 5266 / 256.

For a number in **real µm²** rather than generic gates, map against the PDK
liberty instead:

```sh
LIB=$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
yosys -p "
  read_verilog -I src src/*.v
  synth -top tt_um_fp8_fpu -flatten
  dfflibmap -liberty $LIB
  abc -liberty $LIB
  stat -liberty $LIB
"
```

That last `stat` prints `Chip area for module ...` in µm² — a far better proxy
for what LibreLane will produce than generic gate counts.

---

## 3. Harden and pull the real numbers

```sh
cd ~/tt_um_fp8_fpu
source ~/.venvs/fp8/bin/activate
export PDK_ROOT=~/ttsetup/pdk PDK=sky130A LIBRELANE_TAG=3.0.3

./tt/tt_tool.py --create-user-config
./tt/tt_tool.py --harden
./tt/tt_tool.py --print-warnings
./tt/tt_tool.py --print-stats
```

The three numbers that matter for the next decision:

```sh
# utilisation, cell count, wire length
./tt/tt_tool.py --print-stats

# same fields straight out of the metrics json, plus timing and power
python3 flow/collect_metrics.py --run runs/wokwi --out flow/reports/fp8_narrow
```

**Record them here:**

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Core utilisation (%) | 72.429 | | |
| Cells (excl. fill/tap) | 2396 | | |
| Flip-flops | 227 | | |
| Wire length (µm) | 89 432 | | |
| Setup slack (ns) | | | |
| DRC / LVS | clean | | |

---

## 4. Gate-level regression

Synthesis and place-and-route can break what RTL simulation proved. Replay the
same vectors against the post-PnR netlist:

```sh
cd test
TOP=$(cd .. && ./tt/tt_tool.py --print-top-module)
cp ../runs/wokwi/final/pnl/$TOP.pnl.v gate_level_netlist.v

# smoke first — the gate-level sim is far slower than RTL
FP8_NVEC=5000 make -B GATES=yes

# then the full sweep
GATES=yes JOBS=$(nproc) ./regress.sh
cd ..
```

Gate-level is slow enough that the full 1.84M sweep is an overnight job. Run the
5000-vector smoke before committing to it.

---

## 5. Size the next feature

Take the utilisation `U` and cell count `C` from step 3. Routable ceiling for
this design is around **82 %** (the previous run already needed
`GRT_ALLOW_CONGESTION: 1` at 72 % with 89 mm of wire, so do not plan against
100 %).

```
capacity_at_100%  = C / U
budget            = capacity_at_100% * 0.82 - C
```

Then, against that budget:

| Feature | Estimated cells | Notes |
|---|---:|---|
| CVT (int8/uint8 ↔ fp8) | 120–200 | reuses the LZC/shifter in `fp8_normalize` and all of `fp8_round`; `ROUNDINT` is already half the fp8→int path |
| MACC, reduced fixed accumulator (~28 bit) | 350–450 | range 2⁻¹⁰..2¹⁴; needs its own register + adder + alignment shifter |
| MACC, full exact Kulisch (~40 bit) | 500–800 | covers every FP8 product exactly; almost certainly does not fit in 1×2 |
| FMA, 3-operand narrow (fp8×fp8+fp8→fp8) | 250–400 | fits, but numerically useless — swamps past N≈16 and overflows at 240 |

Decision rule for the 25-day window: **CVT is mandatory** (without it the RISC-V
cannot move operands in or out). Everything else is upside. If the budget after
CVT is under ~400 cells, ship CVT-only and move the accumulator to the FPGA
build.

---

## 6. If the budget is still short

In rough order of return per unit of risk:

1. **Parameterise and strip for the TT build.** `ENABLE_SQRT`,
   `ENABLE_RM_EXOTIC` (ML only ever uses RNE), `ENABLE_MINMAX_SCALB`. The FPGA
   build keeps everything; the ASIC build drops what does not fit. Bonus: it
   yields an area-vs-features table for the thesis.
2. **Liberty-driven synthesis exploration.** See `docs/COMB-OPT.md` — a stronger
   ABC script costs nothing and is risk-free.
3. **`fp8_pre_execute` restructuring** (277 lines of per-opcode special-case
   branching). Likely redundancy between the MULT/DIV and ADD/SUB branches, but
   this is control logic — less predictable payoff than the datapath work.

Do **not** revisit the divider. `fp8_div_iter` is already iterative and costs
roughly 45 flops plus a 12-bit compare-subtract; there is nothing there.
