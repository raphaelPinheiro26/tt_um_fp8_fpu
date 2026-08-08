# Verification — Formal (SymbiYosys)

Prove properties for **all** reachable states, not just sampled stimulus. On this
design, formal owns the **control/handshake fabric**, where simulation coverage
is weakest. The proofs live in [`verification/formal/`](../../verification/formal/).

## Prerequisites

Yosys + SymbiYosys (`sby`) with an SMT solver (yices, boolector, or z3) — the
simplest install is the YosysHQ **OSS CAD Suite** (use the **Linux** release
inside WSL2):

```sh
cd ~
# grab the newest linux-x64 .tgz from the Releases page, then:
#   https://github.com/YosysHQ/oss-cad-suite-build/releases
tar xzf oss-cad-suite-*.tgz
source ~/oss-cad-suite/environment
```

## Run

```sh
cd verification/formal
./run.sh                 # all proofs
./run.sh handshake       # just the buffer proof
sby -f fp8_unpack.sby    # or invoke a single .sby directly
```

Each `.sby` prints `PASS`/`FAIL` per task. A failing `prove`/`bmc` task prints a
counterexample trace (`.vcd`) under `<name>/engine_0/`; a failing `cover` task
means a scenario was **unreachable** (the assertion may be vacuous).

## What is proven

| File | Target | Kind | Claim |
|------|--------|------|-------|
| `fp8_unpack_fv.sv` | `fp8_unpack` | combinational | Classification is **exactly-one** (mutually exclusive + complete) for all 256 words. |
| `fp8_handshake_reg_fv.sv` | `fp8_handshake_reg` | k-induction | The depth-1 elastic buffer is **lossless, order-preserving, non-corrupting** under arbitrary back-pressure. |
| `fp8_elastic_pipeline_fv.sv` | `fp8_elastic_pipeline` | BMC + cover | The full variable-latency pipeline **never drops a result** and keeps `valid_out` stable until consumed. |

### 1. `fp8_unpack` — the "hello world" of formal (combinational)

A classifier is correct only if every input maps to *exactly one* class — one
line: `assert ((c_nan + c_inf + c_zero + c_sub + c_normal) == 1);`. With no
clock, BMC depth 1 hands the solver all 256 inputs symbolically (a full proof,
not 256 directed tests); the `cover` task shows each class is reachable, so the
assertion isn't vacuous. Start here if formal is new to you.

### 2. `fp8_handshake_reg` — the centrepiece (k-induction)

This one buffer is what the whole pipeline is built from (`fp8_elastic_pipeline`
instantiates three: RA, RB, RC). Prove it once and pipeline integrity becomes a
*composition* argument. Properties:

- **`ap_ready_formula`** — `ready_out == (ready_in | ~valid_out)` (accept
  condition).
- **`ap_persist`** — a presented result held under back-pressure stays valid with
  **stable data** next cycle (no dropped beats).
- **`ap_no_create`** — `valid_out` only rises from an accepted input (nothing
  created from nowhere).
- **`ap_data_src`** — `data_out` may only change to the just-accepted `data_in`
  (no corruption).
- **`ap_occ_match` / `ap_occ_bound`** — a shadow counter of `accepted_in −
  accepted_out` stays in `{0,1}` and equals `valid_out` (every item emitted
  exactly once — no loss, no duplication).

The single environment assumption (`ap_src_stable`) is the standard upstream
valid/ready contract (a producer holds `(valid, data)` while stalled) — the same
obligation every AXI-Stream master meets. k-induction (not just BMC) is used
because the occupancy invariant must hold *forever*: `mode prove` runs the base
case **and** the induction step for an unbounded guarantee.

### 3. `fp8_elastic_pipeline` — system-level (BMC + cover)

Here latency is *variable* (`fp8_div_iter` stalls the chain on DIV/SQRT):

- **`ap_out_persist`** — a produced result is never lost while the consumer isn't
  ready (elasticity at the output stage).
- **`ap_valid_sticky`** — `valid_out` only falls on a completed transfer.
- **`cover`** witnesses (observable ports only): a fast result drains; a
  divide/sqrt is accepted; a result drains after a divide was issued; two results
  drain back-to-back (multiple ops in flight).

## Compositional argument (why the math isn't re-proven here)

Data-*value* correctness (does ADD compute A+B?) is covered exhaustively by the
`Fraction`-exact golden model (1.3M+ cases), not by formal. Formal owns control:

```
per-buffer formal (lossless, in-order, non-corrupting)
   ∘ combinational math correct (exhaustive golden sim)
 ⟹ pipeline delivers each op's correct result, in order.
```

*Formal for control, simulation for data* — exactly how production teams split
the work.

## Gotchas worth knowing

- **Immediate, not concurrent assertions.** Open-source Yosys (no Verific) does
  **not** parse `assert property (@(posedge clk) ...)`. All properties use
  immediate assertions inside clocked `always` blocks (`$past`/`$stable`-style).
  `syntax error, unexpected '@'` means a property slipped back into concurrent
  form.
- **No white-box hierarchical refs.** Yosys hierarchical references into a
  flattened DUT (`dut.st`) become undriven wires in the sby flow, so in-order
  delivery is argued compositionally instead of asserting on the divider FSM.

## Exercises

1. **Break it on purpose.** In `fp8_handshake_reg.v` change `ready_out` to
   `ready_in` (drop `| ~valid_out`), re-run `prove`, and read which property
   fails first and why.
2. **Prove liveness properly.** Add a fairness assumption (`ready_in` asserted
   infinitely often) and turn "a result eventually drains" into a real liveness
   assertion.
3. **Lift the flush assumption.** Both proofs assume `flush == 0`; model flush and
   prove it returns the stage to empty (`!valid_out`) in one cycle.
4. **End-to-end data tracking.** Add a symbolic `anyconst` tag to a beat entering
   the pipeline and prove it exits unchanged (compositional → monolithic proof).
