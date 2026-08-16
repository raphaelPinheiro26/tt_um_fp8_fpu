[![gds](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/gds.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/gds.yaml)
[![test](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/test.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/test.yaml)
[![formal](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/formal.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/formal.yaml)
[![uvm](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/uvm.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/uvm.yaml)
[![docs](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/docs.yaml/badge.svg)](https://github.com/raphaelPinheiro26/tt_um_fp8_fpu/actions/workflows/docs.yaml)

# FP8 (E4M3) Floating-Point Unit — Tiny Tapeout

An 8-bit IEEE-style FPU in silicon: **18 operations, five rounding modes, full
IEEE flags and exceptions**, in 1×2 tiles of ChipFoundry `sky130A`.

**Every possible input is tested.** All 1,843,968 combinations of operands,
opcode and rounding mode are replayed against an exact reference model — at RTL
*and* against the post-place-and-route netlist. Nothing is sampled.

That is not achievable in wider formats: a binary FP32 operation has 2⁶⁴ input
combinations, which is why floating-point hardware is normally verified by
theorem proving instead. In a minifloat, exhaustive enumeration comes back
within reach — and it is what made it safe to shrink the datapath by 22 % and
still prove the result is bit-identical.

| | |
|---|---|
| Format | FP8 E4M3 — 1 sign, 4 exponent (bias 7), 3 mantissa |
| Operations | add · sub · mul · div · sqrt · min · max · abs · classify · compare · scalb · roundToIntegral · neg · copySign · **int8/uint8 ↔ fp8** |
| Process | `sky130A` 1×2 tiles — previously `gf180mcu` 2×2 (fabricated) |
| Utilisation | 71.6 %, **0** detailed-routing violations |
| Timing | +44.65 ns setup slack @ 10 MHz · critical path 55.35 ns |
| Power | ≈ 2.3 mW |
| Verification | **1 843 968 vectors, exhaustive, RTL and gate level** |

---

## Documentation

Everything lives in the **[Wiki](../../wiki)** — this file is only the front
door.

| | |
|---|---|
| 🗂 [Project Structure](../../wiki/Project-Structure) | What every folder and file is for. **Start here if you cloned this.** |
| 🚀 [Getting Started](../../wiki/Getting-Started) · [End-to-End Setup](../../wiki/End-to-End-Setup) | Toolchain, simulation, verification, hardening |
| 🏗 [Architecture](../../wiki/Design-Architecture) | Elastic datapath and how the Tiny Tapeout wrapper works |
| 📐 [ISA Reference](../../wiki/ISA-Reference) · [Pin Protocol](../../wiki/Pin-Protocol) | Encoding, flags, exceptions, cycle-by-cycle protocol |
| 🤔 [Design Decisions](../../wiki/Design-Decisions) | Every non-obvious choice, the rejected alternative, and why — including what turned out wrong |
| ✅ [Coverage & Sign-off](../../wiki/Coverage-and-Signoff) | What is proven, how, and what is not |
| 📊 [Results & Metrics](../../wiki/Results-and-Metrics) | Area, timing and power, broken down by the change that produced them |
| 🔌 [RISC-V Integration](../../wiki/RISC-V-Integration) | Attaching the core to CV32E40X (XIF) or PicoRV32 (PCPI), with code |

## Quick start

```sh
# 1. reference vectors
cd Golden_model
python3 gen_vectors_math.py          # -> vectors.hex         (1 311 488)
python3 gen_vectors_math.py --new    # -> vectors_newops.hex  (  527 360)
python3 gen_vectors_math.py --cvt    # -> vectors_cvt.hex     (    5 120)

# 2. full sign-off, every opcode, every input
cd ../test
JOBS=$(nproc) ./regress.sh                    # RTL
GATES=yes JOBS=$(nproc) ./regress.sh          # post-PnR netlist
```

Expected last line: `ALL PASS`.

## Repository layout

```
src/            synthesizable RTL (this is what becomes silicon)
Golden_model/   exact Python reference model + vector generator
test/           top-level sign-off (cocotb) + regress.sh
sim/            block-level testbenches
verification/   formal (SymbiYosys), UVM (pyuvm), DFT
flow/           area/timing/power extraction from the hardening run
docs/wiki/      all documentation — published to the GitHub Wiki
```

Annotated version, with the role of every file:
**[Project Structure](../../wiki/Project-Structure)**.

## License

Apache-2.0 — see [LICENSE](LICENSE).
