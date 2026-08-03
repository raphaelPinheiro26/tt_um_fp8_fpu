# SPDX-License-Identifier: Apache-2.0
# ======================================================================
# runner.py — roda a simulacao cocotb SEM depender do GNU make.
#
# Util no Windows (VS Code nativo), onde `make` normalmente nao esta
# instalado. Espelha exatamente o test/Makefile (mesmas fontes, mesmo
# -I para header_fp8.v, mesmo toplevel `tb`, mesmo modulo de teste `test`).
#
# Uso:
#   python runner.py                # RTL sim (Icarus)
#   SIM=icarus python runner.py     # escolhe o simulador (default: icarus)
#
# Requer: cocotb, Icarus Verilog (iverilog/vvp no PATH).
# ======================================================================
import os
from pathlib import Path

from cocotb_tools.runner import get_runner

HERE = Path(__file__).resolve().parent
SRC = HERE.parent / "src"

# Mesmas fontes do Makefile (header_fp8.v e' `included e resolvido via -I).
PROJECT_SOURCES = [
    "tt_um_fp8_fpu.v", "tiny_fp8_unit.v", "fp8_controller.v",
    "fp8_elastic_pipeline.v", "fp8_handshake_reg.v", "fp8_pre_execute.v",
    "fp8_unpack.v", "fp8_execute_comb.v", "fp8_normalize.v", "fp8_round.v",
    "fp8_div_iter.v", "fp8_direct_ops.v",
]


def main():
    sim = os.environ.get("SIM", "icarus")
    sources = [SRC / f for f in PROJECT_SOURCES] + [HERE / "tb.v"]

    runner = get_runner(sim)
    runner.build(
        verilog_sources=sources,
        hdl_toplevel="tb",
        includes=[SRC],                 # acha `include "header_fp8.v"
        build_dir=HERE / "sim_build" / "rtl",
        always=True,                    # equivalente ao `make -B`
        waves=True,
    )
    runner.test(
        hdl_toplevel="tb",
        test_module="test",
        test_dir=HERE,
    )


if __name__ == "__main__":
    main()
