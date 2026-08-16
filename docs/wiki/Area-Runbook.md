# Area runbook — measure the narrowed datapath and size what fits next

Focused procedure to (a) prove the narrowed datapath is still correct, (b) get
the real sky130 area/timing numbers, and (c) decide how much of CVT/FMA fits in
the remaining budget.

Toolchain setup is **not** repeated here — see [End-to-End-Setup](End-to-End-Setup) (local) or
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

**Measured after the change** (LibreLane, sky130):

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Core utilisation | 72.429 % | **67.641 %** | −4.79 pp |
| Wire length | 89 432 µm | **72 757 µm** | −18.6 % |
| Cells (excl. fill/tap) | 2396 | ~2238 *(derived from utilisation)* | ~−158 |

> The pre-hardening prediction from yosys generic-gate counts was −520 cells /
> ~57 % utilisation. It was wrong by about 3×. Generic gates are not
> proportional to cell area — use `stat -liberty` (section 2) instead. Keeping
> the miss on record because it is the reason section 2 now leads with the
> liberty-based flow.

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

**Recorded:**

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Core utilisation (%) — TT report | 72.429 | **67.641** | −4.79 pp |
| Wire length (µm) | 89 432 | **72 757** | −18.6 % |
| Cells (excl. fill/tap) | 2396 | ~2238 *(derived)* | ~−158 |
| Flip-flops | 227 | *pending* | |
| Setup worst slack (ns) @ T=100 | | **45.893** | |
| Critical path (ns) | | **54.107** | |
| reg→reg critical path (ns) | | **15.83** worst corner | |
| Datapath headroom | | **~63 MHz** | |
| Hold worst slack (ns) | | +0.115 | |
| Total power (W) | | 0.0013 | |
| Max slew violations | | 614 | |

### Reading these numbers — three traps

1. **Two different "utilisation" figures.** `--print-stats` (the TT report)
   says 67.641 %; `collect_metrics.py` reads LibreLane's
   `design__instance__utilization` and says 71.9 %. Different denominators.
   Only compare like with like: the 72.429 % baseline came from the TT report,
   so the TT report figure is the one to track.

2. **`Cell area` == `Core area` is not a bug.** After fill insertion the
   instances physically occupy 100 % of the core, so `design__instance__area`
   equals `design__core__area`. It includes fill.

3. **Total instance count went *up*** (5470 → 5695) even though logic shrank —
   fill expands into whatever space you free. **Never use total instance count
   to measure an area saving.** Use the TT report's
   `N total cells (excluding fill and tap cells)`.

The exact logic-cell and flip-flop counts are in the **gds workflow summary**
("Cell usage by Category"), not in `--print-stats` or `collect_metrics.py`.

> **Do not record `period − setup_slack` as the critical path.** In this design
> the worst setup path is port-to-port through the wrapper and carries 40 ns of
> SDC I/O assumption. Read the **`Reg to Reg`** column of
> `runs/wokwi/*-openroad-stapostpnr/summary.rpt` instead — see
> [Timing Study](Timing-Study).

### Budget

Die capacity is fixed by the 1×2 tile count:

```
capacity = 2396 / 0.72429 = ~3309 cells
current  = 3309 * 0.67641 = ~2238 cells
```

| Ceiling | Usable | Budget |
|---|---:|---:|
| 82 % (conservative) | 2713 | **~475 cells** |
| 85 % (plausible — 18.6 % less wire than the 72 % run) | 2813 | **~575 cells** |

---

## 4. Gate-level regression

Synthesis and place-and-route can break what RTL simulation proved, so the
post-PnR netlist has to be replayed too.

**What gate level is for.** The arithmetic is already proven — the RTL sweep
covers the *complete* input space of the format, and no gate-level run can
strengthen that. What gate level catches is a different class of defect:
X-propagation from uninitialised flops, a mis-mapped cell, a netlist that does
not match the RTL, tie cells left floating. Those show up in the first few
thousand vectors or not at all.

**Measured cost on this design: gate level is only ~2.4× slower than RTL.**
Same 2000-vector streaming test: 4.96 s at RTL, 12.11 s at gate level — about
403 vs 165 vectors/s. The often-quoted "10–50× slower" does not apply to a
design this small; `-DUNIT_DELAY=#1` costs little here.

That makes the **full exhaustive sweep affordable**: the largest opcodes are
327,680 vectors (~33 min each), they run in parallel, so 1,843,968 vectors
finish in roughly **40–50 minutes of wall clock on 12 cores**. Do that rather
than sampling — it upgrades the claim from "RTL exhaustive, gate level
sampled" to *both* exhaustive.

Sampling (§4.4) stays documented for when you are iterating and want a fast
answer, or on a slower machine.

### 4.1 Environment

Everything below needs the venv **and** `PDK_ROOT` — the Makefile pulls the
sky130 cell models from it. `regress.sh` checks both and tells you which is
missing.

```sh
cd ~/tt_um_fp8_fpu
source ~/.venvs/fp8/bin/activate
```

**`PDK_ROOT` is almost certainly not `~/ttsetup/pdk`.** LibreLane resolves the
PDK through ciel, which stores it under a *version hash*, so `--harden` works
while the test Makefile — which expects the classic `$PDK_ROOT/sky130A/...`
layout — fails with:

```
make: *** No rule to make target '.../sky130A/libs.ref/.../primitives.v'
```

Derive it instead of guessing. `PDK_ROOT` must be the directory that
**contains** `sky130A/`:

The ciel version directory usually holds **both `sky130A` and `sky130B`**. Pin
the search to `sky130A` (what TT targets) — an unanchored `find` will happily
return the `sky130B` copy, the suffix strip then matches nothing, and
`PDK_ROOT` silently becomes the full file path:

```sh
SKYV=$(find ~/ttsetup -path "*/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v" 2>/dev/null | head -1)
if [ -z "$SKYV" ]; then
  echo "primitives.v not found under sky130A — check what ciel actually fetched:"
  ls -d ~/ttsetup/pdk/ciel/sky130/versions/*/sky130*/libs.ref/sky130_fd_sc_hd/verilog
else
  export PDK_ROOT=${SKYV%%/sky130A/*}
  echo "PDK_ROOT=$PDK_ROOT"
  ls -l $PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog/{primitives.v,sky130_fd_sc_hd.v}
fi
```

Typical result — note the hash:

```
PDK_ROOT=/home/rapha/ttsetup/pdk/ciel/sky130/versions/8afc8346a57fe1ab7934...
```

Worth adding to your shell profile, since every gate-level session needs it.

### 4.2 Copy the netlist

```sh
cd test
TOP=$(cd .. && ./tt/tt_tool.py --print-top-module)
echo "top = $TOP"

# the post-PnR netlist; if the path differs, find it:
find ../runs -name "*.pnl.v" -o -name "*.nl.v" | tail -5

cp ../runs/wokwi/final/pnl/$TOP.pnl.v gate_level_netlist.v
ls -lh gate_level_netlist.v          # sanity: hundreds of KB, not empty
```

### 4.3 Smoke — minutes

```sh
FP8_NVEC=2000 make -B GATES=yes
```

Expect `TESTS=6 PASS=6`. If the netlist is bad this fails immediately, and the
signature is usually **`x` in the compared bytes** rather than a plausible
wrong number. That means X-propagation from uninitialised state, not an
arithmetic bug — do not go looking in the datapath.

### 4.4 Full sweep — 40–50 min on 12 cores (preferred)

```sh
GATES=yes JOBS=$(nproc) ./regress.sh
```

All 18 opcodes, 1,843,968 vectors, against the post-PnR netlist. This is the
one to run for sign-off.

If you need a fast answer instead — mid-iteration, or on a slower machine —
sample:

```sh
NVEC=20000 GATES=yes JOBS=$(nproc) ./regress.sh
```

20 000 per opcode, sampled evenly across operands and rounding modes by the
testbench loader, plus the back-pressure pass. Roughly 300 k vectors total,
covering every opcode and every rounding mode. Sampled runs are marked in the
summary:

```
PASS  add            20000 / 327680 vectors (sampled)
PASS  abs              256 vectors
```

Opcodes with fewer vectors than `NVEC` (abs, classify, sqrt, roundint, neg,
copysign and the four conversions) are still replayed **exhaustively**, free.

### 4.5 Record

| Check | Result |
|---|---|
| Smoke `FP8_NVEC=2000 GATES=yes` | |
| Sampled sweep `NVEC=20000` | |
| Any `x` in compared bytes | should be none |

State it honestly in the thesis: **RTL is signed off exhaustively, gate level
is signed off by sampling.** That is the normal split; claiming more from a
gate-level run would be overselling it.

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
2. **Liberty-driven synthesis exploration.** See [Combinational-Optimization](Combinational-Optimization) — a stronger
   ABC script costs nothing and is risk-free.
3. **`fp8_pre_execute` restructuring** (277 lines of per-opcode special-case
   branching). Likely redundancy between the MULT/DIV and ADD/SUB branches, but
   this is control logic — less predictable payoff than the datapath work.

Do **not** revisit the divider. `fp8_div_iter` is already iterative and costs
roughly 45 flops plus a 12-bit compare-subtract; there is nothing there.
