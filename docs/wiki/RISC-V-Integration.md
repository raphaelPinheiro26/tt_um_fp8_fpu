# Attaching the FPU to a RISC-V core

> **Status: design proposal.** The FPU core and its interface are implemented
> and exhaustively verified; the coupling described here is **not yet built**.
> Everything below is a concrete plan with code sketches, not documentation of
> working hardware. It is written to be executable by someone else.

The Tiny Tapeout wrapper exists only because 26 pins cannot carry the real
interface. `tiny_fp8_unit` is the block you actually attach to a CPU, and it was
designed for that from the start.

---

## The interface you integrate against

```verilog
module tiny_fp8_unit #(parameter RD_FIFO_DEPTH = 4) (
    input  wire        clk, rst,

    // issue
    input  wire        issue_valid,
    output wire        issue_ready,
    input  wire [7:0]  issue_A, issue_B,
    input  wire [4:0]  issue_opcode,
    input  wire [2:0]  issue_rm,
    input  wire [4:0]  issue_rd,      // destination register tag

    // writeback
    output wire        wb_valid,
    input  wire        wb_ready,
    output wire [7:0]  wb_result,
    output wire [6:0]  wb_flags,
    output wire [4:0]  wb_exceptions,
    output wire [4:0]  wb_rd,         // tag returned with the result

    output wire        fpu_busy,
    input  wire        flush
);
```

Three properties that make integration straightforward:

- **Two independent valid/ready handshakes.** Issue and writeback do not have to
  progress together; the core can issue while draining, and back-pressure on
  either side is handled without loss, duplication or reordering. This is proven
  formally, not just tested — see [Formal Verification](Verification-Formal).
- **`issue_rd` is carried through to `wb_rd`.** The FPU does not care what the
  tag means; it returns whatever it was given, in order. That is exactly the
  scoreboard hook a core needs.
- **`flush` discards in-flight work** for branch misprediction or trap.

Latency is variable: most operations complete in the pipeline, while divide and
square root take roughly one cycle per quotient digit. **Results come back in
issue order regardless**, so the core never has to reorder.

---

## Why CVT is the prerequisite

Operands arrive from an *integer* register file. Without conversion instructions
there is no way to get a number in or a result out — the accelerator would be
unreachable from software. That is why the four conversions were prioritised
over FMA for this tapeout.

With them, the software sequence is direct and needs no fix-up, because the
conversions already follow RISC-V `FCVT` saturation semantics:

```
fp8.cvt.i2f  f0, a0        # int8 in a0    -> fp8
fp8.cvt.i2f  f1, a1
fp8.mul      f2, f0, f1
fp8.cvt.f2i  a2, f2        # fp8           -> int8, saturating
```

---

## Option A — CV32E40X eXtension Interface (recommended)

The [CV32E40X](https://github.com/openhwgroup/cv32e40x) exposes **XIF**, a
standard interface for custom instructions: the core offloads an unrecognised
instruction, an external unit claims it, executes, and returns a result plus a
register tag. It is the mechanism this FPU's interface already resembles.

Academically this is the stronger choice — XIF is the OpenHW standard for ISA
extension, not an ad-hoc coupling.

**Mapping.** XIF has four relevant channels: `issue` (offer), `register`
(operands), `result` (writeback) and `commit` (kill/keep).

| XIF | `tiny_fp8_unit` |
|---|---|
| `issue_valid` / `issue_ready` | `issue_valid` / `issue_ready` |
| `issue_req.instr` | decoded → `issue_opcode`, `issue_rm` |
| `register.rs[0]`, `rs[1]` | `issue_A`, `issue_B` (low byte) |
| `issue_resp.rd` | `issue_rd` |
| `result_valid` / `result_ready` | `wb_valid` / `wb_ready` |
| `result.data` | `{24'b0, wb_result}` |
| `result.rd` | `wb_rd` |
| `commit.commit_kill` | `flush` |

**Sketch** — a decoder plus wiring, no arithmetic:

```verilog
// custom-0 major opcode; funct7 carries the FP8 opcode, funct3 the rounding mode
localparam [6:0] OPC_FP8 = 7'b0001011;   // custom-0

module fp8_xif_shim (
    input  wire        clk, rst,

    // --- XIF issue ---
    input  wire        xif_issue_valid,
    output wire        xif_issue_ready,
    input  wire [31:0] xif_issue_instr,
    input  wire [31:0] xif_rs1, xif_rs2,
    input  wire [4:0]  xif_issue_rd,
    output wire        xif_issue_accept,
    output wire        xif_issue_writeback,

    // --- XIF result ---
    output wire        xif_result_valid,
    input  wire        xif_result_ready,
    output wire [31:0] xif_result_data,
    output wire [4:0]  xif_result_rd,

    input  wire        xif_commit_kill
);
    wire [6:0] opc    = xif_issue_instr[6:0];
    wire [2:0] funct3 = xif_issue_instr[14:12];
    wire [6:0] funct7 = xif_issue_instr[31:25];

    // claim the instruction only if it is ours AND the FPU can take it
    wire mine = (opc == OPC_FP8) && (funct7[6:5] == 2'b00);
    assign xif_issue_accept    = mine;
    assign xif_issue_writeback = mine;          // every op returns a value

    wire fpu_issue_ready;
    assign xif_issue_ready = mine ? fpu_issue_ready : 1'b1;

    wire [7:0] res; wire [6:0] fl; wire [4:0] exc;

    tiny_fp8_unit u_fpu (
        .clk(clk), .rst(rst),
        .issue_valid (xif_issue_valid & mine),
        .issue_ready (fpu_issue_ready),
        .issue_A     (xif_rs1[7:0]),
        .issue_B     (xif_rs2[7:0]),
        .issue_opcode(funct7[4:0]),             // FP8 opcode 0..17
        .issue_rm    (funct3),                  // rounding mode 0..4
        .issue_rd    (xif_issue_rd),
        .wb_valid    (xif_result_valid),
        .wb_ready    (xif_result_ready),
        .wb_result   (res),
        .wb_flags    (fl),
        .wb_exceptions(exc),
        .wb_rd       (xif_result_rd),
        .fpu_busy    (),
        .flush       (xif_commit_kill)
    );

    // zero-extend into the 32-bit register file
    assign xif_result_data = {24'b0, res};

    // exceptions would accumulate into a CSR here (see below)
endmodule
```

The FP8 opcode is 5 bits and `funct7` gives 7, so the encoding has room for the
18 current operations plus future ones, with `funct3` carrying the rounding mode
exactly as RISC-V does for its own FP instructions.

## Option B — PicoRV32 PCPI (fastest to working silicon)

[PicoRV32](https://github.com/YosysHQ/picorv32) exposes **PCPI**, a much simpler
coprocessor interface: the core presents an instruction and two operands, the
coprocessor raises `wr`/`ready` when done. Less standard, but it maps almost
one-to-one and gets you a running system in days rather than weeks.

```verilog
module fp8_pcpi (
    input  wire        clk, resetn,
    input  wire        pcpi_valid,
    input  wire [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2,
    output wire        pcpi_wr,
    output wire [31:0] pcpi_rd,
    output wire        pcpi_wait,
    output wire        pcpi_ready
);
    wire mine = (pcpi_insn[6:0] == 7'b0001011);
    wire [7:0] res; wire wb_v; wire issue_rdy;

    tiny_fp8_unit u_fpu (
        .clk(clk), .rst(~resetn),
        .issue_valid (pcpi_valid & mine & issue_rdy),
        .issue_ready (issue_rdy),
        .issue_A     (pcpi_rs1[7:0]),
        .issue_B     (pcpi_rs2[7:0]),
        .issue_opcode(pcpi_insn[31:27]),
        .issue_rm    (pcpi_insn[14:12]),
        .issue_rd    (5'd0),
        .wb_valid    (wb_v),
        .wb_ready    (1'b1),                    // PCPI takes the result at once
        .wb_result   (res),
        .wb_flags    (), .wb_exceptions(), .wb_rd(),
        .fpu_busy    (), .flush(1'b0)
    );

    assign pcpi_rd    = {24'b0, res};
    assign pcpi_wr    = wb_v;
    assign pcpi_ready = wb_v;
    assign pcpi_wait  = mine & ~wb_v;
endmodule
```

PCPI is strictly in-order and single-outstanding, so this wiring throws away the
pipelining the FPU offers — fine for a first bring-up, wrong for a benchmark.
Use XIF when measuring throughput.

---

## Exception flags

`wb_exceptions` carries the five IEEE flags (`invalid`, `div-by-zero`,
`overflow`, `underflow`, `inexact`) per operation. RISC-V expects them
*accumulated* in `fflags` (CSR `0x001`), sticky until cleared:

```verilog
reg [4:0] fflags;
always @(posedge clk)
    if (rst)                       fflags <= 5'b0;
    else if (csr_write_fflags)     fflags <= csr_wdata[4:0];
    else if (wb_valid & wb_ready)  fflags <= fflags | wb_exceptions;
```

`wb_flags` (the 7 classification bits) has no RISC-V equivalent and is normally
left unconnected — it exists for the `CLASSIFY` instruction and for debug.

---

## Suggested plan

1. **Bring-up.** PicoRV32 + PCPI, a hand-written assembly loop, in Verilator.
   Goal: one correct FP8 multiply from software.
2. **Real integration.** CV32E40X + XIF, exercising multiple operations in
   flight and back-pressure.
3. **Baselines.** Three variants of the same C program:
   soft-float FP8 emulation · this FPU · an FP32 unit such as
   [FPnew](https://github.com/openhwgroup/cvfpu).
4. **Benchmarks.** Dot product → FIR → small GEMV → quantised MLP inference.
   The MLP is the one worth showing: FP8 exists because of it.

**None of this needs an FPGA.** Cycle counts from a Verilator co-simulation are
the same numbers a board would produce; a board adds real Fmax and LUT usage,
which the ASIC hardening reports more rigorously anyway. Do the FPGA build if
there is time, not to get the speedup number.

**Expect the soft-float comparison to look too good.** Emulating FP8 in software
costs tens of instructions per operation, so a 20–50× speedup is real but is an
easy win a reviewer will discount. The FP32-hardware baseline is the comparison
that carries weight, because it answers the question actually being asked: is
FP8 worth the silicon?

---

## Known limitation

`issue_A`/`issue_B` are 8 bits, so operands arrive in the low byte of a 32-bit
register and results are zero-extended back. Packing four FP8 values per
register — the obvious next step for throughput — would require either a SIMD
variant of the datapath or four units, and is out of scope for a 1×2 tile
budget. It is the natural direction for the FPGA build, where area is not the
constraint.
