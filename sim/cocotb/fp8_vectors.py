# SPDX-License-Identifier: Apache-2.0
# Shared helper for the module-level cocotb testbenches under sim/cocotb/.
#
# Locates Golden_model/vectors.hex by walking up from this file, and returns
# the (a, b, op, rm, result, flags, exc) rows. The file is produced by
# Golden_model/gen_vectors_math.py (7 hex columns: A B O R RES FF EE).

import os

FLAG_MASK = 0x7F   # 7 classification-flag bits (header_fp8.v)
EXC_MASK = 0x1F    # 5 IEEE exception bits


def find_vectors():
    """Return the absolute path to Golden_model/vectors.hex.

    Honours the FP8_VEC env var first; otherwise walks up the directory tree
    from this file looking for Golden_model/vectors.hex. This keeps the tests
    runnable regardless of how deep sim/cocotb/<dut>/ sits under the repo root.
    """
    env = os.environ.get("FP8_VEC")
    if env and os.path.isfile(env):
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    d = here
    for _ in range(8):
        cand = os.path.join(d, "Golden_model", "vectors.hex")
        if os.path.isfile(cand):
            return cand
        d = os.path.dirname(d)
    raise FileNotFoundError(
        "Golden_model/vectors.hex not found. Generate it with "
        "`python3 Golden_model/gen_vectors_math.py` or set FP8_VEC."
    )


def load_vectors(nvec=0, op_filter=None, rm_filter=None, path=None):
    """Load golden vectors, optionally filtered by op/rm and evenly sampled.

    nvec <= 0 keeps every (filtered) row; otherwise the kept rows are sampled
    evenly so all opcodes / rounding modes stay represented.
    """
    path = path or find_vectors()
    rows = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) != 7:
                continue
            a, b, op, rm, res, fl, ex = (int(x, 16) for x in p)
            if op_filter is not None and op != op_filter:
                continue
            if rm_filter is not None and rm != rm_filter:
                continue
            rows.append((a, b, op, rm, res, fl & FLAG_MASK, ex & EXC_MASK))
    total = len(rows)
    if nvec <= 0 or nvec >= total:
        return rows
    stride = total / nvec
    return [rows[int(i * stride)] for i in range(nvec)]
