#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
for t in test-*.sh; do
  echo "== $t"
  bash "$t"
done
