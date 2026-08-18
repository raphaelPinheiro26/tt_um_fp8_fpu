# FP8 (E4M3) Floating-Point Unit

An 8-bit IEEE-style floating-point unit taped out through
[Tiny Tapeout](https://tinytapeout.com) — **18 operations, five rounding modes,
full IEEE flags and exceptions**, in 1×2 tiles of ChipFoundry `sky130A`.

What makes it unusual is not the format. It is that the whole thing is
**verified exhaustively**: all 1,843,968 possible combinations of operands,
opcode and rounding mode are replayed against an exact reference model, at RTL
*and* against the post-place-and-route netlist. Nothing is sampled. That is
impossible in FP32 — a binary operation there has 2⁶⁴ input combinations, which
is why floating-point hardware is normally verified with theorem proving. In a
minifloat, enumeration comes back within reach.

---

## At a glance

| | |
|---|---|
| Format | FP8 E4M3 — 1 sign, 4 exponent (bias 7), 3 mantissa |
| Operations | 18: add, sub, mul, div, sqrt, min, max, abs, classify, compare, scalb, roundToIntegral, neg, copySign, and 4 integer conversions |
| Rounding | nearest-even, toward-zero, up, down, nearest-odd |
| Process | `sky130A`, 1×2 tiles · previously `gf180mcu` at 2×2 (fabricated) |
| Utilisation | 71.6 %, 0 detailed-routing violations |
| Timing | reg-to-reg critical path 15.8 ns at the slow corner (~63 MHz headroom) |
| Power | ≈ 2.3 mW |
| Verification | 1 843 968 vectors, exhaustive, RTL **and** gate level |

## Where to go

**New to the project?** → [Project Structure](Project-Structure) explains what
every folder and file is for, and what to touch when you want to change
something.

**Want to run it?** → [Getting Started](Getting-Started), then
[End-to-End Setup](End-to-End-Setup) for the full simulation → verification →
hardening flow.

**New to floating point?** → [Floating-Point Primer](Floating-Point-Primer)
explains the representation, IEEE-754 rules and the E4M3 format from first
principles — including the trap that two different formats are called "E4M3".

**Want to understand it?** → [Architecture](Design-Architecture) for the
datapath and the Tiny Tapeout wrapper, [ISA Reference](ISA-Reference) for the
instruction encoding, [Pin Protocol](Pin-Protocol) for the streaming interface.

**Want to know *why*?** → [Design Decisions](Design-Decisions) records every
non-obvious choice, the alternative rejected, and the reasoning — including the
things that turned out to be wrong.

**Want the numbers?** → [Results & Metrics](Results-and-Metrics) has area,
timing and power broken down by each change that produced them.

**Want to use it in a CPU?** → [RISC-V Integration](RISC-V-Integration) maps the
core's interface onto the CV32E40X eXtension Interface and PicoRV32's PCPI, with
code sketches.

## Verification at a glance

Five independent layers, each catching something the others do not:

| Layer | Establishes |
|---|---|
| Golden vectors | Result, flags and exceptions for **every** input, RTL and gate level |
| Block-level cocotb | Each block in isolation, so failures localise |
| Constrained-random (pyuvm) | Sequences the vector replay does not generate |
| Formal (SymbiYosys) | Elastic-protocol properties over all states: no loss, no reordering, liveness |
| DFT | Scan insertion and flop inventory |

The redundancy is not waste. A real SCALB bug was found by the random testbench
precisely because SCALB was outside the golden-vector set at the time — that
single defect is what motivated the coverage pass this design is built on.

Details: [Coverage & Sign-off](Coverage-and-Signoff).

## Status

The `gf180mcu` chip is fabricated. The `sky130A` version is submitted for the
**ttsky26c** shuttle. The FPU is verified as a block; coupling it to a RISC-V
core and measuring speedup is the next step, and does not require an FPGA.
