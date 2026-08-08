# test/ — official cocotb suite (Tiny Tapeout)

The suite Tiny Tapeout runs on every push. It uses [cocotb](https://docs.cocotb.org/)
to drive the streaming pins like a silicon host and self-checks result/flags/
exceptions in order against `Golden_model/vectors.hex`.

**Full documentation — the six tests, gate-level sim, knobs and waveforms — is in
the wiki:**
[Simulation & Tests](../docs/wiki/Simulation-and-Tests.md#official-cocotb-suite--test).

```sh
make -B                 # RTL sim; expect TESTS=6 PASS=6 FAIL=0
make -B GATES=yes       # gate-level (after hardening → gate_level_netlist.v)
gtkwave tb.fst tb.gtkw  # waveforms
```
