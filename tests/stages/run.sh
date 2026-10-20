#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../require-vm.sh
source ../require-vm.sh
require_vm "${BASH_SOURCE[0]}"
# shellcheck source=../skip-status.sh
source ../skip-status.sh

# Every test's whole output is kept, one file each, so that a failure of a long run can be read afterwards.
log_dir="${VEKRONA_TEST_LOG_DIR:-$(mktemp -d)}"
mkdir -p "$log_dir"
failed=()
skipped=()
for t in test-*.sh; do
  echo "== $t"
  status=0
  bash "$t" 2>&1 | tee "$log_dir/$t.log" || status=${PIPESTATUS[0]}
  case "$status" in
    0) ;;
    "$SKIP_EXIT_STATUS") skipped+=("$t") ;;
    *) failed+=("$t") ;;
  esac
done

echo "logs of every test: $log_dir"
if [[ ${#failed[@]} -gt 0 ]]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "SKIPPED (the machine cannot run them): ${skipped[*]}" >&2
  exit "$SKIP_EXIT_STATUS"
fi
