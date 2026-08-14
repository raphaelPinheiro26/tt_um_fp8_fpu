#!/usr/bin/env bash
# ======================================================================
# regress.sh — full exhaustive regression of tt_um_fp8_fpu.
#
# Replays BOTH golden vector sets against the RTL, split per opcode so a
# failure points straight at the guilty instruction. Everything is
# exhaustive: 1,838,848 vectors in total.
#
#   ./regress.sh                # every opcode, RTL
#   ./regress.sh add sub div    # only these
#   JOBS=4 ./regress.sh         # parallelism (default: nproc)
#   GATES=yes ./regress.sh      # gate level (needs gate_level_netlist.v)
#
# Exit code 0 only if every opcode passes.
# ======================================================================
set -uo pipefail
cd "$(dirname "$0")"

TESTDIR="$(pwd)"
REPO_SRC="$(cd .. && pwd)/src"
GM="$(cd .. && pwd)/Golden_model"
JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}
WORK=${WORK:-/tmp/fp8_regress}
GATES=${GATES:-no}

declare -A OPHEX=( [add]=0 [sub]=1 [mult]=2 [div]=3 [sqrt]=4 [min]=5 [max]=6
                   [abs]=7 [classify]=8 [compare]=9 [scalb]=a [roundint]=b
                   [neg]=c [copysign]=d )
declare -A OPSRC=( [add]=vectors.hex [sub]=vectors.hex [mult]=vectors.hex
                   [div]=vectors.hex [neg]=vectors.hex [copysign]=vectors.hex
                   [sqrt]=vectors_newops.hex [min]=vectors_newops.hex
                   [max]=vectors_newops.hex [abs]=vectors_newops.hex
                   [classify]=vectors_newops.hex [compare]=vectors_newops.hex
                   [scalb]=vectors_newops.hex [roundint]=vectors_newops.hex )

OPS=${*:-add sub mult div sqrt min max abs classify compare scalb roundint neg copysign}

for f in vectors.hex vectors_newops.hex; do
  if [ ! -f "$GM/$f" ]; then
    echo "missing $GM/$f — generate it first:"
    echo "  (cd $GM && python3 gen_vectors_math.py)"
    echo "  (cd $GM && python3 gen_vectors_math.py --new)"
    exit 2
  fi
done

mkdir -p "$WORK"
echo "regress: jobs=$JOBS gates=$GATES work=$WORK"
echo

run_one() {
  local op=$1
  local hex=${OPHEX[$op]} src=${OPSRC[$op]}
  local vec="$WORK/vec_$op.hex" dir="$WORK/run_$op"

  # strip CR so a Windows checkout works too
  tr -d '\r' < "$GM/$src" | awk -v k="$hex" '$3==k' > "$vec"
  local n; n=$(wc -l < "$vec")
  if [ "$n" -eq 0 ]; then echo "SKIP  $op (no vectors)" > "$WORK/res_$op"; return 0; fi

  rm -rf "$dir"; mkdir -p "$dir"
  cp "$TESTDIR"/tb.v "$TESTDIR"/test.py "$TESTDIR"/Makefile "$dir/"

  ( cd "$dir" && FP8_VEC="$vec" FP8_NVEC=0 FP8_NBP=2000 \
      COCOTB_TEST_FILTER=test_vectors_.* \
      make SRC_DIR="$REPO_SRC" GATES="$GATES" ) > "$WORK/log_$op.txt" 2>&1

  if grep -q "all $n vectors passed" "$WORK/log_$op.txt" 2>/dev/null; then
    printf 'PASS  %-9s %8d vectors\n' "$op" "$n" > "$WORK/res_$op"
  else
    { printf 'FAIL  %-9s %8d vectors  %s\n' "$op" "$n" \
        "$(grep -Eo 'result mismatch on op #[0-9]+|error:.*|deadlock' "$WORK/log_$op.txt" | head -1)"
      echo "      log: $WORK/log_$op.txt"; } > "$WORK/res_$op"
  fi
}

rm -f "$WORK"/res_*
running=0
for op in $OPS; do
  run_one "$op" &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running-1)); fi
done
wait

rc=0
for op in $OPS; do
  [ -f "$WORK/res_$op" ] && cat "$WORK/res_$op"
  grep -q '^FAIL' "$WORK/res_$op" 2>/dev/null && rc=1
done

echo
if [ "$rc" -eq 0 ]; then echo "ALL PASS"; else echo "REGRESSION FAILED"; fi
exit $rc
