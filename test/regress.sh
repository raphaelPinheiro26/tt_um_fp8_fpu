#!/usr/bin/env bash
# ======================================================================
# regress.sh — full exhaustive regression of tt_um_fp8_fpu.
#
# Replays the golden vector sets against the RTL, split per opcode so a
# failure points straight at the guilty instruction. 18 opcodes,
# 1,843,968 vectors when everything is exhaustive.
#
#   ./regress.sh                # every opcode, RTL
#   ./regress.sh add sub div    # only these
#   JOBS=4 ./regress.sh         # parallelism (default: nproc)
#   NVEC=20000 ./regress.sh     # sample N per opcode instead of all
#   GATES=yes ./regress.sh      # gate level (needs gate_level_netlist.v + PDK_ROOT)
#   KEEP=1 ./regress.sh         # keep build dirs for inspection
#   WORK=~/fp8_regress ./...    # move the scratch dir
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
# NVEC=0 replays every vector of each opcode (the RTL sign-off). A positive
# value samples that many per opcode, evenly across operands and rounding
# modes — which is what you want at gate level, where the simulation is
# 10-50x slower and the target is synthesis/PnR defects, not arithmetic.
NVEC=${NVEC:-0}

declare -A OPHEX=( [add]=0 [sub]=1 [mult]=2 [div]=3 [sqrt]=4 [min]=5 [max]=6
                   [abs]=7 [classify]=8 [compare]=9 [scalb]=a [roundint]=b
                   [neg]=c [copysign]=d
                   [cvt_f2i]=e [cvt_f2u]=f [cvt_i2f]=10 [cvt_u2f]=11 )
declare -A OPSRC=( [add]=vectors.hex [sub]=vectors.hex [mult]=vectors.hex
                   [div]=vectors.hex [neg]=vectors.hex [copysign]=vectors.hex
                   [sqrt]=vectors_newops.hex [min]=vectors_newops.hex
                   [max]=vectors_newops.hex [abs]=vectors_newops.hex
                   [classify]=vectors_newops.hex [compare]=vectors_newops.hex
                   [scalb]=vectors_newops.hex [roundint]=vectors_newops.hex
                   [cvt_f2i]=vectors_cvt.hex [cvt_f2u]=vectors_cvt.hex
                   [cvt_i2f]=vectors_cvt.hex [cvt_u2f]=vectors_cvt.hex )
declare -A GENFLAG=( [vectors.hex]="" [vectors_newops.hex]="--new"
                     [vectors_cvt.hex]="--cvt" )

OPS=${*:-add sub mult div sqrt min max abs classify compare scalb roundint neg copysign cvt_f2i cvt_f2u cvt_i2f cvt_u2f}

# ---------------------------------------------------------------- preflight
fail_pre() { echo "ERROR: $*" >&2; exit 2; }

# Only require the vector files the requested opcodes actually use.
needed=$(for op in $OPS; do echo "${OPSRC[$op]:-}"; done | sort -u)
for f in $needed; do
  [ -n "$f" ] || continue
  [ -f "$GM/$f" ] || fail_pre "missing $GM/$f
  regenerate with:
    (cd $GM && python3 gen_vectors_math.py ${GENFLAG[$f]:-})"
done

# Guard against the classic mix-up: an older gen_vectors_math.py --new
# defaulted to vectors.hex, silently replacing the arithmetic set.
if echo "$needed" | grep -qx 'vectors.hex'; then
  [ "$(awk '$3=="0"{print;exit}' "$GM/vectors.hex" | wc -l)" -eq 1 ] || \
    fail_pre "$GM/vectors.hex contains no ADD vectors.
  It was probably overwritten by an older 'gen_vectors_math.py --new'. Regenerate:
    (cd $GM && python3 gen_vectors_math.py)"
fi

command -v iverilog >/dev/null || fail_pre "iverilog not on PATH
  sudo apt install iverilog"
command -v cocotb-config >/dev/null || fail_pre "cocotb-config not on PATH.
  Almost always this just means the venv is not active:
    source ~/.venvs/fp8/bin/activate
  If it really is missing:
    pip install -r $TESTDIR/requirements.txt
  Do NOT run this script under sudo — that drops the venv from PATH."
[ -f "$REPO_SRC/header_fp8.v" ] || fail_pre "no RTL at $REPO_SRC"

if [ "$GATES" = yes ]; then
  [ -f "$TESTDIR/gate_level_netlist.v" ] || fail_pre "GATES=yes but $TESTDIR/gate_level_netlist.v is missing.
  Copy it from the hardening run:
    TOP=\$(cd .. && ./tt/tt_tool.py --print-top-module)
    cp ../runs/wokwi/final/pnl/\$TOP.pnl.v $TESTDIR/gate_level_netlist.v"
  [ -n "${PDK_ROOT:-}" ] || fail_pre "GATES=yes needs PDK_ROOT (the Makefile pulls the
  sky130 cell models from it):
    export PDK_ROOT=~/ttsetup/pdk"
  [ -f "$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v" ] || \
    fail_pre "no sky130 cell models under \$PDK_ROOT=$PDK_ROOT"
fi

mkdir -p "$WORK" 2>/dev/null
if [ ! -d "$WORK" ] || ! touch "$WORK/.wtest" 2>/dev/null; then
  fail_pre "work dir $WORK is not writable (owner: $(stat -c %U "$WORK" 2>/dev/null || echo '?'), you are $(id -un)).
  Most likely an earlier 'sudo ./regress.sh' left it owned by root. Remove it:
    sudo rm -rf $WORK
  or use a different one:
    WORK=~/fp8_regress ./regress.sh
  Never run this script under sudo."
fi
rm -f "$WORK/.wtest"

# Stale results from an aborted run would be reprinted in the summary as if
# they were current. Fail loudly rather than lie.
rm -f "$WORK"/res_* 2>/dev/null || fail_pre "cannot clear old results in $WORK"

echo "regress: jobs=$JOBS gates=$GATES nvec=$([ "$NVEC" -eq 0 ] && echo all || echo "$NVEC/op")"
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

  # How many the testbench will actually replay: NVEC=0 means all.
  local want=$n nbp=2000
  if [ "$NVEC" -gt 0 ] && [ "$NVEC" -lt "$n" ];   then want=$NVEC; fi
  if [ "$NVEC" -gt 0 ] && [ "$NVEC" -lt "$nbp" ]; then nbp=$NVEC;  fi

  local rc=0
  ( cd "$dir" && FP8_VEC="$vec" FP8_NVEC="$NVEC" FP8_NBP="$nbp" \
      COCOTB_TEST_FILTER='test_vectors_.*' \
      make SRC_DIR="$REPO_SRC" GATES="$GATES" ) > "$log" 2>&1 || rc=$?

  # Distinguish "the DUT is wrong" from "the run never happened".
  if ! grep -q "streaming $want golden vectors" "$log" 2>/dev/null; then
    { printf 'BUILD %-9s %8d vectors  simulation did not start (make rc=%s)\n' "$op" "$want" "$rc"
      grep -E "error:|No rule to make target|command not found|ModuleNotFoundError|Permission denied|make\[?[0-9]*\]?: \*\*\*" \
           "$log" | head -3 | sed 's/^/        /'
      echo "        log: $log"; } > "$res"
    return 1
  fi

  if grep -q "all $want vectors passed" "$log" 2>/dev/null; then
    if [ "$want" -lt "$n" ]; then
      printf 'PASS  %-9s %8d / %d vectors (sampled)\n' "$op" "$want" "$n" > "$res"
    else
      printf 'PASS  %-9s %8d vectors\n' "$op" "$n" > "$res"
    fi
    [ -n "${KEEP:-}" ] || rm -rf "$dir"
    return 0
  fi

  { printf 'FAIL  %-9s %8d vectors  %s\n' "$op" "$want" \
      "$(grep -Eo 'result mismatch on op #[0-9]+|deadlock[^,]*|AssertionError.*' "$log" | head -1)"
    grep -E "got \[|exp \[" "$log" | head -2 | sed 's/^/        /'
    echo "        log: $log"; } > "$res"
  return 1
}

# ---------------------------------------------------------------- schedule
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
