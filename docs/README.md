# Documentation

All project documentation lives in **[`wiki/`](wiki/)** — the single source of
truth, formatted as GitHub Wiki pages (all English). Start at
[`wiki/Home.md`](wiki/Home.md).

| Page | What it covers |
|------|----------------|
| [Home](wiki/Home.md) | Project overview + highlights |
| [Getting Started](wiki/Getting-Started.md) | End-to-end WSL2 setup: sim → verification → hardening |
| [Tools Cheatsheet](wiki/Tools-Cheatsheet.md) | What each tool does, the flow order, PDKs |
| [Design Architecture](wiki/Design-Architecture.md) | Microarchitecture + elastic pipeline |
| [ISA Reference](wiki/ISA-Reference.md) | Format, opcodes, rounding modes, flags, exceptions |
| [Pin Protocol](wiki/Pin-Protocol.md) | Streaming valid/ready pin protocol (cycle-by-cycle) |
| [Simulation & Tests](wiki/Simulation-and-Tests.md) | cocotb suite, block tests, legacy TBs, golden model |
| [Verification-Formal](wiki/Verification-Formal.md) | SymbiYosys handshake/pipeline proofs |
| [Verification-UVM](wiki/Verification-UVM.md) | pyuvm testbench + the RTL bug it found |
| [Verification-DFT](wiki/Verification-DFT.md) | DFT concepts + scan example |
| [Hardening & Metrics](wiki/Hardening-and-Metrics.md) | GDS, timing, area, power |
| [Timing Study](wiki/Timing-Study.md) | sky130 characterisation + optimisation roadmap |

**[`info.md`](info.md)** is the Tiny Tapeout datasheet text — Tiny Tapeout's docs
workflow reads it from this fixed path.

Each code folder (`test/`, `sim/`, `Golden_model/`, `flow/`, `verification/`, …)
has a short `README.md` stub that points to its wiki page.
