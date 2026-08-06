# Formal Verification Track — SymbiYosys

> Prove properties for **all** reachable states, instead of sampling states
> with stimulus. On this design, formal targets the part simulation is weakest
> at: the elastic `valid/ready` control fabric.

## Prerequisites

- **Yosys** and **SymbiYosys (`sby`)** with an SMT solver (yices, boolector,
  or z3). The simplest install is the YosysHQ **oss-cad-suite** bundle:
  <https://github.com/YosysHQ/oss-cad-suite-build/releases> — download, extract,
  `source environment` (or add `bin/` to `PATH`). Inside WSL2 use the **Linux**
  release, e.g.:

  ```bash
  cd ~
  curl -L -o oss-cad-suite.tgz \
    https://github.com/YosysHQ/oss-cad-suite-build/releases/latest/download/oss-cad-suite-linux-x64-$(date +%Y%m%d 2>/dev/null || echo latest).tgz
  # (if that URL 404s, just grab the newest linux-x64 .tgz asset from the
  #  Releases page above), then:
  tar xzf oss-cad-suite-*.tgz
  source ~/oss-cad-suite/environment
  ```

> **SVA style — why immediate assertions.** Open-source Yosys (no Verific
> front-end, as shipped in the OSS CAD Suite and used in CI) does **not** parse
> concurrent `assert property (@(posedge clk) ...)`. All properties here are
> therefore written as **immediate** assertions inside clocked `always` blocks
> (the "ZipCPU" style) using `$past`/`$stable`-equivalents — the portable form
> that plain Yosys fully supports. If you ever see `syntax error, unexpected
> '@'`, a property slipped back into concurrent form.

## Run

```bash
cd verification/formal
./run.sh                 # all proofs
./run.sh handshake       # just the buffer proof
sby -f fp8_unpack.sby    # or invoke a single .sby directly
```

Each `.sby` prints `PASS`/`FAIL` per task. A `prove`/`bmc` task failing prints
a counterexample trace (`.vcd`) under `<name>/engine_0/`; a `cover` task
failing means a scenario was **unreachable** (the assertion may be vacuous).

## What gets proven, and why here

| File | Target | Kind | Claim |
|------|--------|------|-------|
| `fp8_unpack_fv.sv` | `fp8_unpack` | combinational | Classification is **exactly-one** (mutually exclusive + complete) for all 256 words. |
| `fp8_handshake_reg_fv.sv` | `fp8_handshake_reg` | k-induction | The depth-1 elastic buffer is **lossless, order-preserving, and non-corrupting** under arbitrary back-pressure. |
| `fp8_elastic_pipeline_fv.sv` | `fp8_elastic_pipeline` | BMC + cover | The full variable-latency pipeline **never drops a result** under back-pressure and keeps `valid_out` stable until consumed; covers witness fast/divide/back-to-back drains. |

### 1. `fp8_unpack` — the "hello world" of formal (combinational)

A classifier is only correct if every input maps to *exactly one* class. That
is a single line:

```systemverilog
assert ((c_nan + c_inf + c_zero + c_sub + c_normal) == 1);
```

With no clock, BMC depth 1 hands the SMT solver all 256 inputs symbolically —
a full proof, not 256 directed tests. The `cover` task additionally shows each
class is reachable, so the assertion is not vacuously true. **Start here** if
formal is new to you.

### 2. `fp8_handshake_reg` — the centrepiece (sequential, k-induction)

This one buffer is what the entire pipeline is built from (`fp8_elastic_pipeline`
instantiates three: RA, RB, RC). Prove it once, and the pipeline's data
integrity becomes a *composition* argument rather than a fresh proof. The
properties:

- **`ap_ready_formula`** — `ready_out == (ready_in | ~valid_out)`; documents the
  accept condition.
- **`ap_persist`** — output persistence: a presented result held under
  back-pressure stays valid with **stable data** next cycle. *(No dropped beats.)*
- **`ap_no_create`** — `valid_out` only rises as a consequence of an accepted
  input. *(No data created from nowhere.)*
- **`ap_data_src`** — `data_out` may only ever change to the just-accepted
  `data_in`. *(No corruption.)*
- **`ap_occ_match` / `ap_occ_bound`** — an independent shadow counter of
  `accepted_in − accepted_out` stays in `{0,1}` and equals `valid_out`. *(Every
  accepted item is emitted exactly once — no loss, no duplication.)*

The single environment assumption (`ap_src_stable`) is the **upstream
valid/ready contract**: a producer holds `(valid, data)` stable while stalled.
This is not cheating — it is the standard interface obligation every AXI-Stream
/ ready-valid master already meets; without it *no* buffer could be lossless.

Why k-induction and not just BMC? The occupancy invariant must hold *forever*,
not just for the first N cycles. `mode prove` runs BMC (base case) **and**
induction (step case) so the guarantee is unbounded.

### 3. `fp8_elastic_pipeline` — system-level handshake (BMC + cover)

Here latency is *variable*: `fp8_div_iter` stalls the chain for several cycles
on DIV/SQRT. The proofs:

- **`ap_out_persist`** — the whole point of "elastic": a produced result is
  never lost while the consumer is not ready. (This is the same property proven
  on the buffer as `ap_persist`, here applied to the pipeline's output stage.)
- **`ap_valid_sticky`** — `valid_out` only falls on a completed transfer.
- **`cover`** witnesses (black-box, observable ports only): a fast result
  drains; a divide/sqrt is accepted; a result drains after a divide has been
  issued; two results drain back-to-back (multiple ops in flight).

> **Note — in-order guarantee.** An earlier version asserted the no-overtaking
> property directly on the divider FSM state (`dut.st`). Yosys hierarchical
> references into a flattened DUT are unreliable in the sby flow (they silently
> become an undriven wire), so that white-box assertion is intentionally *not*
> used. In-order delivery is instead established **compositionally**: every
> elastic buffer is proven order-preserving (`fp8_handshake_reg_fv.sv`), and the
> exhaustive golden-model simulation exercises the divide latency directly. To
> assert it white-box, expose a `busy` output from `fp8_elastic_pipeline` and
> check `busy |-> !ready_out` (left as an exercise).

## The compositional argument (why we do NOT re-prove the math here)

Data-*value* correctness — does `ADD` compute `A+B`, does rounding match IEEE —
is **not** proven with formal on this design. It is already covered exhaustively
by the `Fraction`-exact golden model (`../../Golden_model`, driven from
`../../sim` and `../../test`, 1.3M+ cases). Formal instead owns the
**control/handshake fabric**, where directed and random simulation give the
weakest guarantees:

```
per-buffer formal (lossless, in-order, non-corrupting)
        ∘ combinational math correct (exhaustive golden-model sim)
   ⟹ pipeline delivers, for each issued op, the correct result in order.
```

This split — *formal for control, simulation for data* — is exactly how
production teams divide the work, and it is the main methodology takeaway of
this track.

## Exercises (take it further)

1. **Break it on purpose.** In `fp8_handshake_reg.v` change `ready_out` to
   `ready_in` (drop the `| ~valid_out`). Re-run `prove` and read the
   counterexample trace — which property fails first, and why?
2. **Prove liveness properly.** The pipeline covers are bounded witnesses. Add
   a fairness assumption (`ready_in` is asserted infinitely often) and turn
   "a result eventually drains" into a real liveness assertion.
3. **Lift the flush assumption.** Both proofs assume `flush == 0`. Model flush
   and prove it always returns the stage to empty (`!valid_out`) in one cycle.
4. **End-to-end data tracking.** Add a symbolic `anyconst` tag alongside a beat
   entering the pipeline and prove it exits unchanged — turning the
   compositional argument into a single monolithic proof.
