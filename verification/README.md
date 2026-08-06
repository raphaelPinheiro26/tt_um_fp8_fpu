# Verification & DFT Study Track

This directory turns the FP8 (E4M3) FPU into a **hands-on portfolio and
self-study track** for three pillars of modern silicon verification:

| Track | Tooling (open source) | What it proves on this design |
|-------|-----------------------|-------------------------------|
| **[Formal](formal/)** | [Yosys](https://github.com/YosysHQ/yosys) + [SymbiYosys](https://github.com/YosysHQ/sby) | The elastic `valid/ready` pipeline never drops, duplicates, or reorders data, and can never deadlock. |
| **[UVM](uvm/)** | [pyuvm](https://github.com/pyuvm/pyuvm) + [cocotb](https://www.cocotb.org/) + Icarus/Verilator | A reusable, layered constrained-random testbench for the streaming top-level, self-checked against the golden model. |
| **[DFT](dft/)** | [Yosys](https://github.com/YosysHQ/yosys) | Scan-chain insertion, testability analysis, and fault-coverage concepts applied to the FPU. |

These tracks add the *methodology* layers a production project would carry, on
top of the existing exhaustive golden-model sign-off ([`../sim`](../sim),
[`../test`](../test)).

> **This paid off already.** The UVM constrained-random testbench found a real
> control bug in the RTL — a pending `SCALB` corrupting an in-flight `DIV`/`SQRT`
> result — that the exhaustive per-operation vectors missed, because the bug
> lives in the *interaction* between operations. Found, fixed (one line in
> `fp8_elastic_pipeline.v`), and re-validated. See [`uvm/README.md`](uvm/README.md#what-this-testbench-found-a-real-rtl-bug).

---

## Why these three, on this design

The FP8 FPU is unusually well-suited to teach all three:

- **Elastic pipeline → formal.** The core is a chain of depth-1 elastic
  buffers (`fp8_handshake_reg`) wired through `fp8_elastic_pipeline`. Latency
  is *variable* (the iterative divider stalls the chain), so "does the
  handshake still never lose a beat under arbitrary back-pressure?" is a real,
  non-trivial property — and exactly the kind of thing formal proves and
  simulation can only sample.
- **Streaming byte protocol → UVM.** The top-level (`tt_um_fp8_fpu`)
  serialises operands/results over two independent `valid/ready` handshakes
  with sticky-operand and read-full modes. That is a clean bus-functional
  model: a driver that respects `ready`, a monitor that reconstructs
  transactions, and a scoreboard that scores against the reference — textbook
  UVM.
- **Taped-out ASIC → DFT.** This is a real sky130 tapeout with 161 flip-flops.
  Making those flops controllable/observable via scan, and reasoning about
  stuck-at fault coverage, is the missing manufacturing-test layer.

## Suggested study order

The tracks are independent, but if you are learning the area from scratch this
order builds the concepts most naturally:

1. **Formal first (`formal/`).** Smallest surface, fastest feedback loop, and
   it forces you to state precisely what "correct handshake" *means*. Start
   with `fp8_handshake_reg` (one buffer), then the full pipeline.
2. **UVM second (`uvm/`).** Once you can specify properties, the UVM
   scoreboard's checks feel natural. You will build the classic component
   hierarchy (sequence → driver → DUT → monitor → scoreboard).
3. **DFT last (`dft/`).** Structural, post-RTL concern. Easiest to appreciate
   after you understand functional verification, because DFT is about the
   faults functional tests *cannot* see.

Each subdirectory has its own `README.md` with: the concepts, how they map to
this specific RTL, exact commands to run, and a short "exercises" section to
take the study further.

## Quick start

```bash
# Formal (needs yosys + sby)
cd verification/formal && ./run.sh

# UVM (needs a Verilog simulator: iverilog or verilator, + pip deps)
pip install -r verification/uvm/requirements.txt
cd verification/uvm/pyuvm && make

# DFT flop-inventory / scan demo (needs yosys)
cd verification/dft && yosys scan_insert.ys
```

See each track's README for prerequisites and a full walkthrough.

## Glossary (one-liners)

- **Formal / model checking** — mathematically proving a property holds for
  *all* reachable states, rather than sampling states with stimulus.
- **BMC (bounded model check)** — proves a property for the first *k* cycles;
  finds shallow bugs fast.
- **k-induction** — proves a property holds *forever* by showing it is
  preserved across any *k* consecutive steps.
- **Cover** — asks the solver to *reach* a state (used to prove a scenario is
  possible, e.g. "a transfer can happen").
- **UVM (Universal Verification Methodology)** — a standard class library and
  component pattern (agent/driver/monitor/sequencer/scoreboard/env/test) for
  building reusable constrained-random testbenches.
- **Scoreboard** — the component that compares DUT output against a reference
  model and flags mismatches.
- **DFT (Design for Test)** — RTL/netlist modifications that make a chip
  testable on a manufacturing tester (scan, ATPG, MBIST, boundary scan).
- **Scan chain** — flip-flops stitched into a shift register in test mode so
  the tester can load/observe every state bit.
- **ATPG** — Automatic Test Pattern Generation: tools that compute the input
  patterns that expose manufacturing (e.g. stuck-at) faults.
- **Fault coverage** — fraction of modelled faults a test set can detect.
