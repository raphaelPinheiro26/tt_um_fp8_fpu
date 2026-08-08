# DFT track — Design for Test

Scan-chain / ATPG / fault-coverage concepts applied to this sky130 tapeout: a
flop inventory of the real design and a worked scan-insertion example. (No scan
is in the taped-out chip — see the wiki for why.)

**Full documentation — fault models, controllability/observability, the scan
procedure, ATPG and exercises — is in the wiki:**
[Verification-DFT](../../docs/wiki/Verification-DFT.md).

```sh
cd verification/dft
yosys scan_insert.ys                                            # flop inventory
iverilog -g2012 -o scan_tb fp8_scan_reg.v tb_scan_reg.v && vvp scan_tb
```
