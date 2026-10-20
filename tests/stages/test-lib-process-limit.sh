#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A test process that sources tests/lib.sh inside another one inherits the process limit of its parent, which an
# unprivileged process cannot raise. The limit below is above the user's current thread count (room to fork, a thousand
# threads' worth) but below what tests/lib.sh would compute (twice the thread count plus 2000), so sourcing must leave it alone.
threads=$(ps -eLo pid= -u "$UID" | wc -l)
limit=$((threads + 1000))
status=0
bash -c 'ulimit -u "$2"; source "$1/tests/lib.sh"; ulimit -u' _ "$ROOT" "$limit" >"$work/out" 2>"$work/err" || status=$?
[[ "$status" -eq 0 ]] || die "sourcing tests/lib.sh inside a test failed with status $status: $(cat "$work/err")"
[[ ! -s "$work/err" ]] || die "sourcing tests/lib.sh inside a test printed errors: $(cat "$work/err")"
[[ "$(<"$work/out")" == "$limit" ]] || die "sourcing tests/lib.sh changed the inherited process limit $limit to $(<"$work/out")"
log "ok: sourcing tests/lib.sh inside a test never raises the inherited process limit"
