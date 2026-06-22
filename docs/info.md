<!---

This file is used by Tiny Tapeout to generate the project datasheet page.
Write the documentation for your project here.

-->

## How it works

This project tapes out an **8-bit floating-point unit** in the **FP8 E4M3**
format (1 sign bit, 4 exponent bits with bias 7, 3 mantissa bits). The core,
`tiny_fp8_unit`, performs **add, subtract, multiply and divide** with several
IEEE-754 rounding modes and produces classification flags and exception flags.

The core's native interface is far wider than Tiny Tapeout's pin budget (it
needs ~32 input bits and ~28 output bits). To fit, the top-level wrapper
`tt_um_fp8_fpu` time-multiplexes everything onto a single 8-bit data bus and
walks a small **phase state machine**. The host advances each phase with a
single **STEP** strobe, so the host fully controls the timing:

```
LOAD_A → LOAD_B → LOAD_CTRL → (ISSUE → WAIT) → READ_RES → READ_FLG → READ_EXC → …
```

Operands A and B and the control word `{rm, opcode}` are loaded on three STEP
pulses; the FPU then issues the operation and computes; the result, flags and
exceptions are read back on three more STEP pulses.

### Pinout

**Inputs**
- `ui_in[7:0]` — `DATA_IN`: operand byte, then `{rm[2:0]=ui_in[7:5], opcode[4:0]=ui_in[4:0]}`
- `uio_in[0]` — `STEP`: rising edge advances the FSM one phase

**Outputs**
- `uo_out[7:0]` — `DATA_OUT`: result / flags / exceptions depending on the phase
- `uio_out[7]` — `RESULT_VALID`
- `uio_out[6]` — `FPU_BUSY`
- `uio_out[5:3]` — `PHASE[2:0]` (current FSM state)

## How to test

After reset the FSM is in `LOAD_A`. To compute `A op B`:

1. Drive `A` on `ui_in`, pulse `STEP`.
2. Drive `B` on `ui_in`, pulse `STEP`.
3. Drive `{rm, opcode}` on `ui_in`, pulse `STEP`.
4. Wait until `RESULT_VALID` (`uio_out[7]`) is high, then read the result on `uo_out`.
5. Pulse `STEP` to read flags, again for exceptions, again to return to `LOAD_A`.

Example — `1.0 + 1.0`: FP8 `1.0 = 0x38`, ADD opcode `= 0x00`. Write `0x38`,
`0x38`, `0x00`; the result is `0x40` (= 2.0).

The cocotb test in `test/test.py` automates this for add, subtract and multiply.

## External hardware

None required. Any host that can drive 8 inputs and the STEP strobe and read 8
outputs (a microcontroller, an FPGA, the Tiny Tapeout demo board, or a logic
analyser) can operate the FPU.
