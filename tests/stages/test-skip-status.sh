#!/usr/bin/env bash
# A test that cannot run here ends with SKIP_EXIT_STATUS, which the runners count apart from passes and failures: an exit status
# of 0 would read as a pass for something that never ran.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

skip_as_root "the last check needs a regular user, and root is not one"

status=0
(skip "this machine cannot run it") 2>/dev/null || status=$?
[[ "$status" -eq "$SKIP_EXIT_STATUS" ]] || die "skip ended with status $status, not $SKIP_EXIT_STATUS"
log "ok: skip ends the test with the skip status"

[[ "$SKIP_EXIT_STATUS" -ne 0 && "$SKIP_EXIT_STATUS" -ne 1 ]] || die "the skip status $SKIP_EXIT_STATUS reads as a pass or a failure"
log "ok: the skip status is neither a pass nor a failure"

require_user_namespaces
status=0
unshare -r bash -c 'source "$1/tests/lib.sh"; skip_as_root "root is not refused here"' _ "$ROOT" 2>/dev/null || status=$?
[[ "$status" -eq "$SKIP_EXIT_STATUS" ]] || die "a test that needs a regular user ended with status $status as root, not the skip status"
log "ok: a test that needs a regular user is skipped under root"

status=0
bash -c 'source "$1/tests/lib.sh"; skip_as_root "root is not refused here"' _ "$ROOT" || status=$?
[[ "$status" -eq 0 ]] || die "a regular user was skipped or failed (status $status)"
log "ok: a regular user is not skipped"
