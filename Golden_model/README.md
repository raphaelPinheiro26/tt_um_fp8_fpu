# Golden_model/ — FP8 E4M3 reference

The verification oracle: a **mathematical specification** (exact value as a
`Fraction` + IEEE exceptions), verified identical to the earlier bit-accurate RTL
golden model across all 1,310,720 cases.

- `fp8_common.py` — FP8 E4M3 codec (unpack, exact value as a Fraction).
- `fp8_math.py` — `fp8_math(A, B, opcode, rm) -> (result, flags, exc)`.
- `gen_vectors_math.py` — generates the 7-column `vectors.hex`.
- `vectors.hex` — committed golden vectors (~30k subset; no-arg run regenerates
  the full 1.3M set).

**Full documentation — the model files, API, exception handling and vector-
generation flags — is in the wiki:**
[Simulation & Tests](../docs/wiki/Simulation-and-Tests.md#golden-model--golden_model).
Opcode / rounding / flag / exception encodings: [ISA Reference](../docs/wiki/ISA-Reference.md).

```sh
python3 gen_vectors_math.py            # ADD/SUB/MULT/DIV, 5 modes
python3 gen_vectors_math.py --quick    # small smoke sample
```
