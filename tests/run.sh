#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
cd "$REPO"

failed=()

run_suite() {
  local name="$1"
  shift
  echo "=== $name"
  "$@" || failed+=("$name")
}

run_suite "error pipeline" python3 -B -m unittest discover -v -s tests/errors -p 'test_*.py'
run_suite "stage helpers" bash tests/stages/run.sh
run_suite "Anaconda add-ons" python3 -B -m unittest discover -v -s iso/anaconda/tests
run_suite "VM serial helpers" python3 -B -m unittest discover -v -s tests/vm
run_suite "VM USB passthrough checks" bash tests/vm/test-usb-claims.sh

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED suites: ${failed[*]}" >&2
  exit 1
fi
echo "all suites passed"
