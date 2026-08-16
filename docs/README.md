# Documentation

All project documentation lives in **[`wiki/`](wiki/)** — the single source of
truth, written as GitHub Wiki pages (English). The `docs` workflow publishes it
to the repository Wiki on every push. Start at [`wiki/Home.md`](wiki/Home.md).

`info.md` in this folder is the **datasheet Tiny Tapeout publishes with the
chip**. Its path is fixed by the shuttle tooling, so it cannot move into
`wiki/`. Keep it in sync with the ISA and pin protocol pages.

| Page | What it covers |
|------|----------------|
| [Home](wiki/Home.md) | Landing page and navigation |
| [Project Structure](wiki/Project-Structure.md) | Every folder and file, and what to touch to change something |
| [Getting Started](wiki/Getting-Started.md) | Toolchain and first simulation |
| [End-to-End Setup](wiki/End-to-End-Setup.md) | Full flow on WSL2: simulation → verification → LibreLane → metrics |
| [Tools Cheatsheet](wiki/Tools-Cheatsheet.md) | Command reference |
| [Floating-Point Primer](wiki/Floating-Point-Primer.md) | How floating point works, IEEE-754 rules, and the E4M3 format |
| [Design Architecture](wiki/Design-Architecture.md) | Elastic datapath, the three result paths, and the Tiny Tapeout wrapper in detail |
| [ISA Reference](wiki/ISA-Reference.md) | Opcodes, rounding modes, flags, exceptions |
| [Pin Protocol](wiki/Pin-Protocol.md) | Cycle-by-cycle streaming protocol |
| [Design Decisions](wiki/Design-Decisions.md) | Every non-obvious choice and its rejected alternative |
| [Coverage & Sign-off](wiki/Coverage-and-Signoff.md) | Exhaustive verification: what is proven and what is not |
| [Simulation & Tests](wiki/Simulation-and-Tests.md) | cocotb testbenches |
| [Formal](wiki/Verification-Formal.md) | SymbiYosys proofs |
| [UVM](wiki/Verification-UVM.md) | pyuvm constrained-random |
| [DFT](wiki/Verification-DFT.md) | Scan insertion, flop inventory |
| [Results & Metrics](wiki/Results-and-Metrics.md) | Area, timing, power by change |
| [Hardening](wiki/Hardening-and-Metrics.md) | Running LibreLane and reading its outputs |
| [Area Runbook](wiki/Area-Runbook.md) | Reproducing the area numbers step by step |
| [Timing Study](wiki/Timing-Study.md) | Clock sweep and Fmax |
| [Combinational Optimization](wiki/Combinational-Optimization.md) | Techniques for reducing combinational logic |
| [RISC-V Integration](wiki/RISC-V-Integration.md) | Coupling the core to CV32E40X or PicoRV32 |
