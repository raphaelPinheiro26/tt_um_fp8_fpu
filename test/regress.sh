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
#   KEEP=1 ./regress.sh         # keep build dirs for inspection
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

# ---------------------------------------------------------------- preflight
fail_pre() { echo "ERROR: $*" >&2; exit 2; }

for f in vectors.hex vectors_newops.hex; do
  [ -f "$GM/$f" ] || fail_pre "missing $GM/$f
  regenerate with:
    (cd $GM && python3 gen_vectors_math.py)
    (cd $GM && python3 gen_vectors_math.py --new)"
done

# Guard against the classic mix-up: gen_vectors_math.py --new used to default
# to vectors.hex, silently replacing the arithmetic set with the extended one.
have_arith=$(awk '$3=="0"{print;exit}' "$GM/vectors.hex" | wc -l)
have_new=$(awk '$3=="4"{print;exit}'  "$GM/vectors_newops.hex" | wc -l)
[ "$have_arith" -eq 1 ] || fail_pre "$GM/vectors.hex contains no ADD vectors.
  It was probably overwritten by 'gen_vectors_math.py --new'. Regenerate:
    (cd $GM && python3 gen_vectors_math.py)"
[ "$have_new" -eq 1 ] || fail_pre "$GM/vectors_newops.hex contains no SQRT vectors.
  Regenerate:
    (cd $GM && python3 gen_vectors_math.py --new)"

command -v iverilog   >/dev/null || fail_pre "iverilog not on PATH"
command -v cocotb-config >/dev/null || fail_pre "cocotb not installed (pip install -r requirements.txt)"
[ -f "$REPO_SRC/header_fp8.v" ] || fail_pre "no RTL at $REPO_SRC"
if [ "$GATES" = yes ] && [ ! -f "$TESTDIR/gate_level_netlist.v" ]; then
  fail_pre "GATES=yes but $TESTDIR/gate_level_netlist.v is missing"
fi

mkdir -p "$WORK"
echo "regress: jobs=$JOBS gates=$GATES"
echo "         rtl=$REPO_SRC"
echo "         work=$WORK"
printf '         params: %s\n' \
  "$(grep -E '^`define NRM_(MW|G|ACCW|QDIV)' "$REPO_SRC/header_fp8.v" | tr -s ' ' | tr '\n' ' ')"
echo

# ---------------------------------------------------------------- one opcode
run_one() {
  local op=$1
  local hex=${OPHEX[$op]} src=${OPSRC[$op]}
  local vec="$WORK/vec_$op.hex" dir="$WORK/run_$op" log="$WORK/log_$op.txt"
  local res="$WORK/res_$op"

  tr -d '\r' < "$GM/$src" | awk -v k="$hex" '$3==k' > "$vec"
  local n; n=$(wc -l < "$vec")
  if [ "$n" -eq 0 ]; then
    printf 'SKIP  %-9s no vectors for opcode %s in %s\n' "$op" "$hex" "$src" > "$res"
    return 0
  fi

  rm -rf "$dir"; mkdir -p "$dir"
  cp "$TESTDIR"/tb.v "$TESTDIR"/test.py "$TESTDIR"/Makefile "$dir/"
  [ "$GATES" = yes ] && cp "$TESTDIR"/gate_level_netlist.v "$dir/"

  local rc=0
  ( cd "$dir" && FP8_VEC="$vec" FP8_NVEC=0 FP8_NBP=2000 \
      COCOTB_TEST_FILTER='test_vectors_.*' \
      make SRC_DIR="$REPO_SRC" GATES="$GATES" ) > "$log" 2>&1 || rc=$?

  # Distinguish "the DUT is wrong" from "the run never happened".
  if ! grep -q "streaming $n golden vectors" "$log" 2>/dev/null; then
    { printf 'BUILD %-9s %8d vectors  simulation did not start (make rc=%s)\n' "$op" "$n" "$rc"
      grep -E "error:|No rule to make target|command not found|ModuleNotFoundError|Permission denied|make\[?[0-9]*\]?: \*\*\*" \
           "$log" | head -3 | sed 's/^/        /'
      echo "        log: $log"; } > "$res"
    return 1
  fi

  if grep -q "all $n vectors passed" "$log" 2>/dev/null; then
    printf 'PASS  %-9s %8d vectors\n' "$op" "$n" > "$res"
    [ -n "${KEEP:-}" ] || rm -rf "$dir"
    return 0
  fi

  { printf 'FAIL  %-9s %8d vectors  %s\n' "$op" "$n" \
      "$(grep -Eo 'result mismatch on op #[0-9]+|deadlock[^,]*|AssertionError.*' "$log" | head -1)"
    grep -E "got \[|exp \[" "$log" | head -2 | sed 's/^/        /'
    echo "        log: $log"; } > "$res"
  return 1
}

# ---------------------------------------------------------------- schedule
rm -f "$WORK"/res_*
running=0
for op in $OPS; do
  run_one "$op" &
  running=$((running+1))
  if [ "$running" -ge "$JOBS" ]; then
    if ! wait -n 2>/dev/null; then :; fi
    running=$((running-1))
  fi
done
wait

rc=0
for op in $OPS; do
  if [ -f "$WORK/res_$op" ]; then
    cat "$WORK/res_$op"
    grep -qE '^(FAIL|BUILD)' "$WORK/res_$op" && rc=1
  else
    echo "LOST  $op (no result file)"; rc=1
  fi
done

echo
if [ "$rc" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "REGRESSION FAILED — see the logs above."
  echo "BUILD = the simulation never ran (toolchain/paths). FAIL = the DUT mismatched."
fi
exit $rc
