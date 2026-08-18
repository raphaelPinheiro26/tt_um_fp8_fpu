# Timing study

Where the frequency ceiling actually is, why the obvious number is wrong, and
what it would take to raise it.

**The chip ships as-is.** It meets its declared 10 MHz with enormous margin.
This page is the characterisation and future-work chapter, not a list of
problems.

---

## 1. The number that is wrong, and why

`flow/collect_metrics.py` reports:

```
Setup worst slack   44.650 ns
Critical path (T − slack)   55.350 ns
Estimated Fmax      18.07 MHz
```

**That 18 MHz is not a property of this circuit.** It is an artefact of two
things the summary line hides.

`runs/wokwi/*-openroad-stapostpnr/summary.rpt` separates them:

| Corner | Setup worst slack | Setup slack, **reg→reg only** |
|---|---:|---:|
| **Overall (worst)** | **44.65 ns** | **84.17 ns** |
| `nom_tt_025C_1v80` | 52.36 ns | 92.23 ns |
| `nom_ss_100C_1v60` | 45.16 ns | 84.39 ns |
| `nom_ff_n40C_1v95` | 55.04 ns | 95.07 ns |

The two columns differ by ~40 ns, which means **the worst setup path is not
register-to-register**. `report_checks` names it:

```
Startpoint: uio_in[5]  (input port clocked by clk)
Endpoint:   uio_out[1] (output port clocked by clk)
Path Group: clk
```

That is `STICKY_B → IN_READY`: a purely combinational path from an input pin to
an output pin, through the wrapper's handshake logic. And the Tiny Tapeout
`base.sdc` constrains it with:

```
set_input_delay  20 ns
set_output_delay 20 ns
```

Those are **default placeholders in the shuttle's SDC**, not characterised
values for any real host. They consume 40 of the 55.35 ns before the circuit
contributes anything.

## 2. The number that is right

```
T                                  = 100.00 ns
worst-corner reg→reg setup slack   =  84.17 ns
────────────────────────────────────────────────
reg→reg critical path              =  15.83 ns   →  ~63 MHz
```

| | Value |
|---|---|
| reg→reg critical path, worst corner (`max_ss_100C_1v60`) | **15.83 ns** |
| reg→reg critical path, typical corner | 7.77 ns |
| Datapath headroom | **~63 MHz** worst corner · ~129 MHz typical |
| Setup violations | **0** in all ten corners |
| Hold worst slack (reg→reg) | +0.116 ns |
| Hold violations | **0** in all ten corners |

The arithmetic datapath is roughly **3.5× faster** than the headline figure
suggests.

### How to state it

> The register-to-register critical path is 15.8 ns at the slow corner
> (`ss`, 100 °C, 1.60 V), giving the datapath headroom to approximately 63 MHz.
> The absolute worst setup path is port-to-port through the wrapper's handshake
> logic and is dominated by the 40 ns of external I/O delay assumed by the
> default Tiny Tapeout SDC. The declared 10 MHz reflects the serial streaming
> interface and a conservative I/O constraint, not the limit of the arithmetic
> unit.

**Do not write "Fmax = 63 MHz."** This is read from a run constrained at 100 ns:
the tool reached 15.8 ns without being asked to, but a *closed* frequency
requires re-hardening at that period, where hold, slew and routing all re-enter.
Say **headroom to ~63 MHz**, not *achieves 63 MHz*.

## 3. What this says about the design

The bottleneck is the **protocol adapter forced by the 26-pin budget, not the
arithmetic**. Three previously separate observations collapse into one
argument:

- the wrapper exists only because the core's interface does not fit on the pins
  ([Architecture](Design-Architecture));
- the datapath has headroom to ~63 MHz while the chip declares 10 MHz;
- the worst path in the whole design is wrapper handshake logic against
  placeholder I/O constraints.

Which is the direct case for [attaching the core to a CPU](RISC-V-Integration):
`tiny_fp8_unit` has no wrapper, no byte serialisation and no external I/O
constraint. That is where the performance is.

## 4. Raising it, if it ever matters

In order of leverage:

1. **Pipeline the C0 stage.** The combinational cone
   `unpack → pre-execute → execute → normalize` — including the barrel shifter
   — is the reg→reg path. Buffering cannot cross it; only a register can. This
   is the only structural lever.
2. **Constrain the I/O honestly.** If the port-to-port path ever matters, the
   20/20 ns defaults should be replaced with values derived from the actual host
   (the board's RP2040 is not a 20 ns-delay device). This is an SDC change, not
   an RTL one.
3. **Split the divider iteration.** `fp8_div_iter` does one digit per cycle
   through a 12-bit compare-subtract; it is not on the critical path today, but
   it would become relevant well above 63 MHz.

## 5. The catch nobody mentions

Tightening the clock makes the resizer insert buffers and upsize cells, which
**increases area** — on a design that already needed
`PL_TARGET_DENSITY_PCT = 75` to route at 71.6 % utilisation with four signal
layers.

It is entirely plausible that in 1×2 tiles this design is **area-limited before
it is timing-limited**: the tight-period sweep points may fail in detailed
routing rather than in STA. That is not a failed experiment — it is the result,
and it reinforces §4.1: the lever is pipelining C0 (which trades flops for path
length at roughly constant congestion), not squeezing the clock.

## 6. Reproducing this

Free, from the existing run:

```sh
cat runs/wokwi/*-openroad-stapostpnr/summary.rpt

# is the worst path reg→reg or port→port?
grep -E "^Startpoint|^Endpoint|^Path Group" \
  runs/wokwi/*-openroad-stapostpnr/nom_tt_025C_1v80/checks.rpt | head -12
```

**Read the `Reg to Reg` column, not `Setup Worst Slack`**, unless you have
verified that the worst path really is register-to-register.

Only if a closed frequency is genuinely needed:

```sh
python3 flow/sweep_clock.py --periods 40 --out flow/reports/sweep40
```

One point first — each one re-hardens the whole design. Choose it near the
expected answer; a target far above the achieved path applies no pressure and
teaches nothing. `sweep_clock.py` edits `src/config.json` and restores it, so
after any interrupted run confirm `CLOCK_PERIOD` is back to 100 before
submitting to a shuttle.

## 7. Method note

The mistake this page corrects is worth remembering, because it is the same one
that produced a 3× area misestimate elsewhere in this project: **an aggregate
reported by a convenience tool was accepted without checking what it
aggregated.** `period − slack` silently mixed 40 ns of SDC assumption with the
real path. The fix was to open the underlying report and separate the path
groups.

Both corrections are recorded in [Design Decisions](Design-Decisions).
