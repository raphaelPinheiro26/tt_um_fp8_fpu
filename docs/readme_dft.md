# DFT Track — Design for Test

> Functional verification (formal + UVM) proves the design is *logically*
> correct. **DFT** is about a different question: once the chip is fabricated,
> how do you tell a good die from a defective one on a tester in seconds? This
> track covers the concepts and applies the Yosys-native parts to this sky130
> tapeout.

## Why this matters for *this* chip

The taped-out design has **161 flip-flops** (see the main README) on ChipFoundry
sky130. Silicon has manufacturing defects — shorts, opens, stuck nodes. A
manufacturing tester must, for each die, apply patterns and check responses fast
enough to be economical. But most of those 161 flops are buried deep in the
pipeline: you cannot reach them from the 8 input pins directly. DFT is the set
of structural additions that make internal state **controllable** and
**observable** so test patterns can actually exercise it.

TinyTapeout adds its own wrinkle: many user designs share one die behind a mux
harness, so the shuttle itself relies on testability of the mux/IO ring. Your
project's job is to be scan-friendly so it *could* be folded into such a flow.

## The core ideas

### Fault models
Real defects are physical, but test tools reason about **logical fault models**.
The workhorse is the **single stuck-at** model: assume one node is permanently
stuck at 0 (`sa0`) or 1 (`sa1`) and ask "what input pattern makes the output
differ between the good and faulty circuit?". **Fault coverage** = fraction of
all modelled faults a test set detects; production ASICs target 95–99%+.

### Controllability & observability
- **Controllability** — can you force an internal node to a chosen value?
- **Observability** — can you propagate an internal node's value to an output?

A deep pipeline flop scores badly on both from the primary pins alone. Scan
fixes that structurally.

### Scan chains (the main technique)
Scan insertion replaces every flip-flop with a **mux-D scan flop**: a 2:1 mux in
front of the D input selects between the *functional* next-state and a *scan_in*
value, controlled by a global **scan_enable**. All scan flops are then stitched
into one (or several) shift register(s):

```
scan_in ─▶[FF]─▶[FF]─▶[FF]─▶ … ─▶[FF]─▶ scan_out
             (scan_enable = 1 : shift mode)
```

Test procedure per pattern:
1. **Shift in** (scan_enable=1): clock a chosen state into every flop.
2. **Capture** (scan_enable=0): one functional clock — combinational logic
   reacts, results land back in the flops.
3. **Shift out** (scan_enable=1): clock the captured state out to `scan_out`,
   comparing against the expected response (and shifting the next pattern in).

This turns an unobservable sequential problem into a **combinational** one that
ATPG can solve efficiently.

### ATPG & test compression
**ATPG** (Automatic Test Pattern Generation) computes the shift-in patterns that
sensitise and propagate each fault. Large designs use **compression** (on-chip
decompressor/compactor, e.g. EDT) so short tester patterns expand to many scan
values — cutting test time and data volume.

### Other DFT you'd meet (not all needed here)
- **MBIST** — Memory Built-In Self-Test. Not applicable: this FPU has **no
  RAM**, only flops. (Worth knowing it exists; it is the standard answer for
  on-chip memories.)
- **Boundary scan / JTAG (IEEE 1149.1)** — a scan chain around the *I/O ring*
  to test board-level interconnect and enable in-system programming.
- **LBIST** — Logic BIST: an on-chip LFSR generates pseudo-random scan patterns
  for in-field self-test.

## Hands-on

### 1. Inventory the state (runnable, Yosys)
```bash
cd verification/dft
yosys scan_insert.ys
```
This synthesises the whole design flat, prints the flip-flop count per module
and for the flattened top (the exact flops a scan chain must include), maps them
to a single DFF type, and writes `netlist_flat.v`. Read `flops_by_module.txt`
to see where the state lives (the elastic buffers RA/RB/RC, the divider, the
controller FSM, the top-level I/O deserialiser).

> Full scan stitching + ATPG needs a dedicated tool. Open source: the **Fault**
> framework (Yosys + OpenSTA) does DFT and stuck-at ATPG for sky130. Commercial:
> Tessent, Modus, DFTMAX. This script covers the Yosys-native groundwork.

### 2. See what scan insertion produces (runnable, iverilog)
```bash
iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb
```
`fp8_scan_reg.v` is a register with an explicit inserted scan mux (mirroring the
data register inside `fp8_handshake_reg`). The testbench demonstrates the two
things scan buys you: it **scans an arbitrary state in and back out** (full
controllability + observability) and confirms **functional behaviour is
unchanged** when `scan_enable=0`.

## Exercises

1. **Coverage intuition.** Pick a small combinational block (`fp8_unpack`) and,
   by hand, find an input that detects a `sa0` on the `is_inf` node. Convince
   yourself why some faults need scan to reach at all.
2. **Chain budgeting.** From `flops_flat.txt`, compute the shift cycles for one
   pattern with a single chain vs four balanced chains. What does that do to
   test time?
3. **Install Fault.** Set up the open-source Fault framework on the sky130
   netlist and generate a real stuck-at coverage number for the FPU.
4. **Reset & scan.** The core uses an async reset. Discuss how test mode must
   control asynchronous set/reset pins so they don't corrupt the shift.
