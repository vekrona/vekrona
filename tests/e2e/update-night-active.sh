#!/usr/bin/env bash
set -euo pipefail

# Somebody is at the keyboard when the night run starts: it asks first. No answer skips the night; the "Install and
# reboot" button stores the offline update. DNF_SYSTEM_UPGRADE_NO_REBOOT keeps the VM up, so the scenario ends with the
# transaction stored and the marker written, which is the moment before the reboot.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/update-e2e-lib.sh"

SHORT_ASK_TIMEOUT_SEC=2
LONG_ASK_TIMEOUT_SEC=120
STEP_TIMEOUT_SEC=120
export RESULT=/tmp/vekrona-update-night-active

trap 'run_cleanups cleanup_test_update close_notification_centre "vekrona-dev run sudo rm -f \"\$RESULT.out\" \"\$RESULT.status\""' EXIT

result_written() { vekrona-dev run test -s "$RESULT.status"; }
export -f result_written

vekrona-dev session
install_build_tools
publish_decoy_update
use_only_the_test_repo
publish_test_update
run_check_expecting_only_the_test_update

night_env "VEKRONA_UPDATE_ASK_TIMEOUT=$SHORT_ASK_TIMEOUT_SEC" DNF_SYSTEM_UPGRADE_NO_REBOOT=1
started="$(guest_now)"
vekrona-dev run sudo systemctl start --wait "$NIGHT_UNIT"
night_log "$started" | grep -q "answered 'timeout'" || die "the unanswered question was not treated as a timeout: $(night_log "$started")"
marker_absent || die "an unanswered question installed the updates"
[[ "$(installed_test_version)" == 1.0 ]] || die "an unanswered question changed $TEST_PKG"
log "ok: an unanswered question skips the night"

night_env "VEKRONA_UPDATE_ASK_TIMEOUT=$LONG_ASK_TIMEOUT_SEC" DNF_SYSTEM_UPGRADE_NO_REBOOT=1
# The night run checks first, so the question comes seconds after it starts, and its toast hides after five seconds;
# the centre keeps it.
open_notification_centre
vekrona-dev spawn --root "$RESULT.out" -- bash -c "systemctl start --wait $NIGHT_UNIT; echo \$? >$RESULT.status"
# The pointer rests where the last click was, which is on the button's word, and the screenshot draws the pointer over it.
vekrona-dev move 600 500
vekrona-dev click-text '^reboot$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- result_written
[[ "$(vekrona-dev run cat "$RESULT.status")" == 0 ]] || die "the night run failed after Install and reboot"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- marker_exists
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- offline_transaction_stored
[[ "$(installed_test_version)" == 1.0 ]] || die "$TEST_PKG changed before the offline boot"
log "ok: Install and reboot stores the offline update and writes the marker, before any reboot"
