#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
export PYTHONDONTWRITEBYTECODE=1
cd "$REPO"

failed=()
skipped=()

run_suite() {
  local name="$1"
  shift
  echo "=== $name"
  "$@" || failed+=("$name")
}

run_suite "error pipeline" python3 -B -m unittest discover -v -s tests/errors -p 'test_*.py'
run_suite "stage helpers" bash tests/stages/run.sh
# The add-ons import the real pyanaconda and pykickstart (DBus structures, spoke
# base classes), which are installed in the vekrona-dev guest, not on a host.
# VEKRONA_REQUIRE_ANACONDA=1 (set by `vekrona-dev test`) makes their absence a failure.
if python3 -c 'import pyanaconda, pykickstart' 2>/dev/null; then
  run_suite "Anaconda add-ons" python3 -B -m unittest discover -v -s iso/anaconda/tests
elif [[ "${VEKRONA_REQUIRE_ANACONDA:-}" == 1 ]]; then
  echo "=== Anaconda add-ons"
  echo "pyanaconda/pykickstart are not importable but VEKRONA_REQUIRE_ANACONDA=1" >&2
  failed+=("Anaconda add-ons")
else
  echo "=== Anaconda add-ons: NOT RUN (pyanaconda/pykickstart not installed; run \`vekrona-dev test\`)"
  skipped+=("Anaconda add-ons")
fi
run_suite "VM serial helpers" python3 -B -m unittest discover -v -s tests/vm
run_suite "VM USB passthrough checks" bash tests/vm/test-usb-claims.sh
run_suite "VM start lock" bash tests/vm/test-lock.sh

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED suites: ${failed[*]}" >&2
  exit 1
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "NOT RUN (missing dependency, covered by vekrona-dev test): ${skipped[*]}" >&2
fi
echo "all suites that could run passed"
