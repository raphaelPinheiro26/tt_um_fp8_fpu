# Legacy Verilog testbenches (reference only)

These are the original stand-alone Verilog testbenches for the FP8 FPU. They
are **not** part of the Tiny Tapeout flow (the taped-out RTL lives in `../src`
and the cocotb verification lives in `../test`), but they are kept here as a
reference and for quick local debugging.

| Testbench | Exercises |
|-----------|-----------|
| `tb_fp8_unit.v`         | the full `tiny_fp8_unit` (controller + pipeline) |
| `tb_fp8_controller.v`   | `fp8_controller` issue/writeback + rd FIFO |
| `tb_fp8_elastic.v`      | `fp8_elastic_pipeline` handshake |
| `tb_fp8_elastic_stream.v` | streaming throughput on the elastic pipeline |
| `tb_handshake_elastic.v`| the `fp8_handshake_reg` building block |
| `tb_fp8_golden.v`       | **self-checking** replay of `../vectors.hex` |

## Running them

Because the design moved into `../src`, point the compiler at it with `-I` and
list the source files from there. With Icarus Verilog, run from the repository
root so the golden testbench finds `vectors.hex` in the working directory:

```bash
# from the repository root
iverilog -g2012 -I src -o sim/golden.out \
    sim/tb_fp8_golden.v \
    src/tiny_fp8_unit.v src/fp8_controller.v src/fp8_elastic_pipeline.v \
    src/fp8_handshake_reg.v src/fp8_pre_execute.v src/fp8_unpack.v \
    src/fp8_execute_comb.v src/fp8_normalize.v src/fp8_round.v
vvp sim/golden.out
```

`tb_fp8_golden.v` looks for `vectors.hex` in the current working directory
first, then next to itself. If you run from elsewhere, pass the path explicitly:

```bash
vvp sim/golden.out +vecfile=/abs/path/to/vectors.hex
```

Useful plusargs: `+maxfail=N` (default 50), `+stop_on_fail`.
