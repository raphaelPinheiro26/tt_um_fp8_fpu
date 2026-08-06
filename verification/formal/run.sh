#!/usr/bin/env bash
# Run every formal proof in this directory.
#   ./run.sh            # run all
#   ./run.sh unpack     # run one (matches *unpack*.sby)
#
# Requires: yosys + sby (SymbiYosys) + a SMT solver (yices/boolector/z3).
# Install (Ubuntu): the oss-cad-suite bundle is the easiest one-shot install:
#   https://github.com/YosysHQ/oss-cad-suite-build/releases
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v sby >/dev/null 2>&1; then
  echo "ERROR: 'sby' (SymbiYosys) not found on PATH."
  echo "Install the YosysHQ oss-cad-suite: https://github.com/YosysHQ/oss-cad-suite-build"
  exit 1
fi

filter="${1:-}"
rc=0
for sby in *.sby; do
  [ -e "$sby" ] || continue
  if [ -n "$filter" ] && [[ "$sby" != *"$filter"* ]]; then
    continue
  fi
  echo "==================================================================="
  echo ">>> $sby"
  echo "==================================================================="
  # -f: overwrite previous work directory
  sby -f "$sby" || rc=1
done

if [ "$rc" -eq 0 ]; then
  echo "ALL FORMAL TASKS PASSED"
else
  echo "SOME FORMAL TASKS FAILED (see output above)"
fi
exit "$rc"
