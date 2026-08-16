# Simplifying large combinational logic — what actually works

Notes on reducing the combinational cost of this design, ordered by return per
unit of risk. Written after the `NRM_G`/`NRM_ACCW`/`NRM_MW` work, which removed
22.5 % of the gates without touching a single Boolean equation.

## First: why Karnaugh maps do not apply

A K-map is a visual aid for **4 to 6 variables**. The combinational cone here
takes two 8-bit operands, a 5-bit opcode and a 3-bit rounding mode — 24 inputs,
a truth table with 16.7 million rows. There is no manual process for that.

The algorithmic successors do not help either:

- **Quine–McCluskey** is exact but exponential; it dies well before 20 inputs.
- **Espresso** (heuristic two-level) handles more, but produces a *two-level*
  sum-of-products. For a datapath that is a catastrophe: a 4-bit adder as flat
  SOP is enormous, while as a ripple structure it is tiny. Two-level
  minimisation is for control logic and PLAs, not arithmetic.
- Modern synthesis (yosys + ABC) already runs stronger multi-level algorithms
  than anything done by hand. **You will not beat the optimiser at its own game.**

The leverage is at a level the optimiser cannot reach: it can only minimise the
function you gave it. It cannot know that you gave it a function 12 bits wider
than necessary.

---

## Level 1 — Structural. This is where the wins are.

The optimiser preserves your function exactly. If the function itself carries
redundant information, only you can remove it.

### Width analysis

Carry only bits that can affect the output. This project's two biggest wins:

- `NRM_ACCW` was 26 bits for a format with a **4-bit significand**, sized so the
  alignment shift was always exact. Reduced to 10 → −909 gates.
- `NRM_MW` was 16 bits carrying 7 bits of information → −278 gates, −8 flops.

Method: parameterise the width, sweep it downward, and let an exhaustive vector
set tell you the floor. Do not derive it by hand — see the two sticky bugs in
[Coverage-and-Signoff](Coverage-and-Signoff) that a hand derivation missed.

This generalises, and for low-precision formats it is a publishable result in
its own right: minimal datapath width analysis for reduced-precision FP.

### Resource sharing

One instance used by several operations instead of one per operation. Already
done here in two places worth studying:

- `fp8_normalize` merged the ADD/SUB and DIV normalisers into **one** priority
  encoder and **one** barrel shifter, parameterised by magnitude/exponent/offset.
- `fp8_div_iter` serves both DIV and SQRT from one compare-subtract datapath.

Look for it wherever two blocks differ only in operand selection.

### Time multiplexing

Trade cycles for area. `fp8_div_iter` already does 1 bit/cycle instead of a
combinational divide. Any remaining "wide combinational thing used rarely" is a
candidate — but check the utilisation first, because adding a state machine and
handshake can cost more than the array you removed.

### Strength reduction

Replace an expensive operator with a cheap one: multiply by a constant becomes
shift+add, division by a power of two becomes a shift, comparison against a
constant becomes a few gates. Synthesis does the obvious cases; it misses ones
that depend on invariants only you know.

---

## Level 2 — Don't-cares. The biggest untapped source here.

The synthesiser must produce correct output for **every** input combination,
including ones that can never occur. Every impossible combination you fail to
declare is optimisation left on the table.

Concretely in this design: `fp8_pre_execute` already filters NaN/Inf/zero cases
and sets `use_special`. Downstream, `fp8_execute_comb` and `fp8_normalize` still
contain logic that is only reachable for operand classes `pre_execute` has
already excluded. The tool cannot know that.

Three ways to exploit it:

1. **Restructure so the impossible case is not expressible.** Best option — e.g.
   pass a narrow "operand class" enum instead of raw flags, so illegal
   combinations have no encoding.
2. **Tell the tool.** SystemVerilog `assume` properties, or `x` assignments in
   unreachable branches (`default: result = 'x;`) which yosys treats as
   don't-care and ABC exploits. This is free area — but only correct if the case
   truly cannot occur, so pair it with a formal proof that it cannot.
3. **Observability don't-cares.** Outputs that are ignored downstream in certain
   modes. ABC's `dch` and `mfs` passes find some of these automatically.

Using `x` for genuinely unreachable branches is one of the highest
area-per-effort moves available, and it is also the most dangerous — an `x` in a
reachable branch is a bug that simulation may hide and silicon will not.

---

## Level 3 — Let the tools work harder. Free and risk-free.

Yosys' default `synth` runs a modest ABC script. You can do considerably better
at zero risk, because ABC is equivalence-preserving by construction.

### Map against the real liberty, not generic gates

Generic-gate counts mislead: sky130 has complex cells (`a21oi`, `o211a`,
`a2bb2oi`) that absorb 3–5 generic gates each. Always measure with the PDK:

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

`stat -liberty` reports chip area in µm².

### Stronger ABC scripts

Replace the default with an area-oriented script and compare:

```sh
# inside yosys, after synth -flatten and dfflibmap:
abc -liberty $LIB -script "+strash;dch,-f;if;mfs2;lutpack;&get,-n;&dch,-f;&nf;&put;"
```

Simpler, well-tried area recipes to benchmark against each other:

- `resyn2` — general purpose, fast
- `compress2rs` — more aggressive area, slower
- `dch -f` followed by mapping — uses SAT-based structural choices; usually the
  best area result, and slow

Run each, record `stat -liberty`, keep the winner. Typical spread is a few
percent — small next to the 22.5 % that came from width analysis, but it is free.

### Yosys passes worth trying explicitly

`opt_share` (shares operators across mutually-exclusive branches), `opt_merge`
(merges identical cells), `opt_dff -sat`, `memory_map`, `share`. Add them to a
custom script and measure; they are all equivalence-preserving.

### Flattening

Hierarchy boundaries block cross-module optimisation. `flatten` before `abc`
lets the tool share logic between `fp8_execute_comb` and `fp8_normalize`. Costs
readability of the netlist, not of your RTL.

---

## The safety net that makes aggressive restructuring possible

Manual restructuring is only sane with a proof. This repo already used the right
technique once — the comment at the top of `fp8_normalize.v`:

> *Equivalencia BIT-A-BIT com a versao anterior PROVADA por SAT (yosys miter, 0
> contra-exemplos sobre todo o espaco de entradas).*

For a purely combinational block, that is a **complete** proof over all inputs —
strictly stronger than any vector set. Use it for every restructuring:

```sh
yosys -p "
  read_verilog -I src -DTOP=old old/fp8_pre_execute.v; rename fp8_pre_execute old_m
  read_verilog -I src        src/fp8_pre_execute.v;    rename fp8_pre_execute new_m
  miter -equiv -flatten old_m new_m miter_m
  hierarchy -top miter_m; sat -verify -prove trigger 0 -show-inputs -show-outputs
"
```

For sequential blocks the equivalent is `sat -seq N` or a `.sby` proof — the
`verification/formal/` directory already has the structure for it.

Workflow: restructure → prove equivalence by SAT → measure area → keep or
discard. That loop is fast and carries no correctness risk, which is what makes
it worth doing under a deadline.

---

## What I would look at next in this design

1. **`fp8_pre_execute` (277 lines).** Long per-opcode `if/else` chains for
   NaN/Inf/zero handling. The MULT and DIV branches share most of their
   structure (sign = XOR, Inf/zero propagation rules); ADD/SUB differ mainly in
   the effective sign. A table-driven form — compute a small "case class", then
   one shared result mux — often shrinks this class of code substantially. This
   is control logic, so payoff is less predictable than the datapath work.
2. **Don't-care declaration on the unreachable branches** downstream of
   `pre_execute`, per Level 2. Cheap, and this design has a lot of them.
3. **`fp8_direct_ops` duplicates `do_round()`** from `fp8_round`. They sit in
   different pipeline stages so they cannot literally share an instance, but the
   ROUNDINT path could plausibly be folded into the main rounder instead of
   carrying its own shifter and rounding decision.

Not worth revisiting: the divider. `fp8_div_iter` is already iterative — roughly
45 flops and a 12-bit compare-subtract. There is nothing to recover there.
