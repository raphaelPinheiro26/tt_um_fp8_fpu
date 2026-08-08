# Verification & DFT study track

Turns the FP8 FPU into a hands-on study track for three pillars of silicon
verification — **formal**, **UVM**, and **DFT** — all with open-source tooling,
on top of the exhaustive golden-model sign-off.

**The full documentation lives in the wiki** (single source):

- [Formal (SymbiYosys)](../docs/wiki/Verification-Formal.md) — proofs that the
  elastic `valid/ready` pipeline never drops, duplicates or reorders data.
- [UVM (pyuvm)](../docs/wiki/Verification-UVM.md) — layered constrained-random
  testbench, and the real RTL bug it found.
- [DFT](../docs/wiki/Verification-DFT.md) — scan/ATPG concepts and a worked scan
  example.
- [Simulation & Tests](../docs/wiki/Simulation-and-Tests.md) — the sim/test
  stack these build on.

Suggested order: formal → UVM → DFT.

```sh
cd verification/formal && ./run.sh                          # formal
cd verification/uvm/pyuvm && make                           # UVM
cd verification/dft && yosys scan_insert.ys                 # DFT
```
