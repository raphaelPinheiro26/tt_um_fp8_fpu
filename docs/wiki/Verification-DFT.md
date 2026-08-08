# Verification — DFT (Design for Test)

Functional verification proves the design is *logically* correct. **DFT** asks a
different question: once fabricated, how do you sort good dies from defective ones
on a tester in seconds? Code: [`verification/dft/`](../../verification/dft/).

## Why this matters for this chip

The hardened netlist has **227 flip-flops** (`dfrtp`) on ChipFoundry sky130. Most
are buried deep in the pipeline — unreachable from the 8 input pins directly. DFT
is the set of structural additions that make internal state **controllable** and
**observable** so test patterns can exercise it. Tiny Tapeout adds a wrinkle:
many designs share one die behind a mux harness, so the shuttle relies on
testability of the mux/IO ring; your project's job is to be scan-friendly.

## Is DFT in the taped-out chip? No.

Be honest about this (recruiters respect it):

- The `tt_um_fp8_fpu` on silicon has **no internal scan chain / ATPG**.
- Tiny Tapeout's "scan chain" is for **I/O access / muxing** of tiles — not
  stuck-at fault testing of your logic.
- The fixed 8-in/8-out/8-bidir interface leaves **no room** for dedicated scan
  pins, and the TT hardening flow doesn't enable the optional DFT step.

The tool underneath (LibreLane) **does** support DFT via the open-source **Fault**
framework (scan insertion + ATPG + fault coverage) — it's simply left off in the
TT flow.

## Core ideas

### Fault models
Test tools reason about **logical fault models**. The workhorse is **single
stuck-at**: assume one node is permanently stuck at 0 (`sa0`) or 1 (`sa1`) and ask
"what input makes the output differ between the good and faulty circuit?".
**Fault coverage** = fraction of modelled faults a test set detects; production
ASICs target 95–99 %+.

### Controllability & observability
- **Controllability** — can you force an internal node to a chosen value?
- **Observability** — can you propagate its value to an output?

A deep pipeline flop scores badly on both from the primary pins alone. Scan fixes
that structurally.

### Scan chains (the main technique)
Scan insertion replaces every flop with a **mux-D scan flop** (a 2:1 mux on D
selecting functional next-state vs `scan_in`, controlled by a global
`scan_enable`), then stitches them into a shift register:

```
scan_in ─▶[FF]─▶[FF]─▶[FF]─▶ … ─▶[FF]─▶ scan_out   (scan_enable=1: shift mode)
```

Per pattern: **shift in** (scan_enable=1) a chosen state → **capture**
(scan_enable=0) one functional clock → **shift out** (scan_enable=1) the captured
state to `scan_out`, comparing against the expected response. This turns an
unobservable sequential problem into a **combinational** one ATPG can solve.

### ATPG & other DFT
**ATPG** computes the shift-in patterns that sensitise and propagate each fault;
large designs add **compression** (EDT). Also worth knowing: **MBIST** (not
applicable — this FPU has no RAM), **boundary scan / JTAG** (I/O-ring chain), and
**LBIST** (on-chip LFSR pattern generation).

## Hands-on

```sh
# 1) flop inventory of the real design (the chain a tool would stitch)
cd verification/dft && yosys scan_insert.ys

# 2) what scan insertion produces, self-checking testbench
iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb
```

`scan_insert.ys` synthesises the design flat, prints the flop count per module
and for the flattened top, maps them to a single DFF type, and writes
`netlist_flat.v` + `flops_by_module.txt` (see where state lives: the RA/RB/RC
buffers, the divider, the controller FSM, the I/O deserialiser). `fp8_scan_reg.v`
makes the inserted scan mux explicit; its testbench scans an arbitrary state in
and back out (full controllability + observability) and confirms functional
behaviour is unchanged when `scan_enable=0`.

## Making it real

The pragmatic route for a portfolio/thesis number: feed the sky130 gate netlist
to **Fault** and report an actual **stuck-at coverage %** for the FPU — no chip
change, just characterisation.

## Exercises

1. **Coverage intuition.** For `fp8_unpack`, find by hand an input that detects a
   `sa0` on the `is_inf` node; see why some faults need scan to reach at all.
2. **Chain budgeting.** From `flops_flat.txt`, compute shift cycles for one
   pattern with a single chain vs four balanced chains — effect on test time?
3. **Install Fault.** Set up the open-source Fault framework on the sky130 netlist
   and generate a real stuck-at coverage number.
4. **Reset & scan.** The core uses an async reset — discuss how test mode must
   control async set/reset pins so they don't corrupt the shift.
