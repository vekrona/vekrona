#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=require-vm.sh
source "$REPO/tests/require-vm.sh"
require_vm "${BASH_SOURCE[0]}"
# shellcheck source=skip-status.sh
source "$REPO/tests/skip-status.sh"
export PYTHONDONTWRITEBYTECODE=1
cd "$REPO"

# The whole output of every suite is kept, one file each (the stage helpers keep one per test): a failure in the middle of a long
# run is read from there afterwards, not guessed from a rerun.
LOG_DIR="${VEKRONA_TEST_LOG_DIR:-$(mktemp -d)}"
mkdir -p "$LOG_DIR"
export VEKRONA_TEST_LOG_DIR="$LOG_DIR"
failed=()
skipped=()

# A suite that exits SKIP_EXIT_STATUS passed what it could run and says, on its stderr, which tests it skipped.
run_suite() {
  local name="$1" status=0
  shift
  echo "=== $name"
  "$@" 2>&1 | tee "$LOG_DIR/${name// /-}.log" || status=${PIPESTATUS[0]}
  case "$status" in
    0) ;;
    "$SKIP_EXIT_STATUS") skipped+=("$name (some tests skipped)") ;;
    *) failed+=("$name") ;;
  esac
}

run_suite "error pipeline" python3 -B -m unittest discover -v -s tests/errors -p 'test_*.py'
run_suite "audio watchdog" python3 -B -m unittest discover -v -s tests/audio -p 'test_*.py'
run_suite "update pipeline, user side" python3 -B -m unittest discover -v -s tests/updates -p 'test_*.py'
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

echo "logs of every suite: $LOG_DIR"
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED suites: ${failed[*]}" >&2
  exit 1
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "NOT RUN (this machine cannot run them, or a dependency is missing; \`vekrona-dev test\` runs them): ${skipped[*]}" >&2
fi
echo "all suites that could run passed"
