# FP8 (E4M3) Floating-Point Unit — Tiny Tapeout

An 8-bit IEEE-style floating-point unit (FP8, **E4M3**) taped out on **sky130**
via Tiny Tapeout (shuttle ttsky26c). A 12-operation FPU with an **elastic,
pipelined** datapath, an **iterative variable-latency** divide/sqrt unit, and a
streaming `valid/ready` byte interface — verified exhaustively against a
`Fraction`-exact reference model, and hardened to GDS.

This wiki is the guided tour. The source and per-folder docs live in the main
repository.

## Highlights

- **Real silicon:** taped out on ChipFoundry sky130, 1×2 tiles, 2 396 logic
  cells (227 flip-flops); TT precheck 15/15 ✅, gate-level tests 6/6.
- **Exhaustively verified:** 1,310,720 golden vectors (256×256 operands × ops ×
  rounding modes), 0 mismatches.
- **Full verification methodology track:** formal (SymbiYosys), UVM (pyuvm), and
  DFT — see [Verification-Formal](Verification-Formal),
  [Verification-UVM](Verification-UVM), [Verification-DFT](Verification-DFT).
- **A real bug, found by UVM:** the constrained-random pyuvm testbench caught a
  control bug the exhaustive vectors missed — a pending `SCALB` corrupting an
  in-flight `DIV`/`SQRT` result. Found, root-caused, fixed in one line,
  re-validated. Story on [Verification-UVM](Verification-UVM).

## Start here

- New to the repo? → [Getting Started](Getting-Started) (WSL2 setup).
- Just want the commands? → [Tools Cheatsheet](Tools-Cheatsheet).
- How the FPU works → [Design Architecture](Design-Architecture).
- Physical results → [Hardening & Metrics](Hardening-and-Metrics).

## What is FP8 E4M3?

An 8-bit float: `[sign 1b][exponent 4b, bias 7][mantissa 3b]`. Range of normals
≈ ±0.015625 … ±240. Used in ML accelerators for compact activations/weights.
This unit implements add/sub/mul/div/sqrt plus min/max/abs/neg/copysign/classify/
compare/scalb/round-to-integral, with IEEE rounding modes and exception flags.

## Map

| Area | Page |
|------|------|
| Environment setup | [Getting Started](Getting-Started) |
| Tool commands & flow order | [Tools Cheatsheet](Tools-Cheatsheet) |
| Microarchitecture | [Design Architecture](Design-Architecture) |
| Format · opcodes · rounding · flags | [ISA Reference](ISA-Reference) |
| Simulation & tests | [Simulation & Tests](Simulation-and-Tests) |
| Formal proofs | [Verification-Formal](Verification-Formal) |
| UVM testbench + the bug | [Verification-UVM](Verification-UVM) |
| DFT (and what's real) | [Verification-DFT](Verification-DFT) |
| GDS, timing, area, power | [Hardening & Metrics](Hardening-and-Metrics) |
