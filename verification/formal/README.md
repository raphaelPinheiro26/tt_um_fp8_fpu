# Formal verification (SymbiYosys)

Proofs that the elastic `valid/ready` control fabric is lossless, order-preserving
and non-corrupting under arbitrary back-pressure (`fp8_unpack`,
`fp8_handshake_reg`, `fp8_elastic_pipeline`).

**Full documentation — prerequisites, what each proof claims, the compositional
argument, gotchas and exercises — is in the wiki:**
[Verification-Formal](../../docs/wiki/Verification-Formal.md).

```sh
source ~/oss-cad-suite/environment   # yosys + sby + solvers
cd verification/formal
./run.sh                 # all proofs
sby -f fp8_unpack.sby    # a single proof
```
