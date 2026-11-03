#!/usr/bin/env bash
set -euo pipefail

# A user can see an update finish even when the update reloads systemd. dnf upgrading systemd makes the package scriptlets
# re-execute PID 1 in the middle of vekrona-update-now.service; the scenario's unit does just that and then ends, with the
# exit status the case asks for. vekrona-update must show the unit's output and end with its result.
# The second case fails the unit on purpose, which the guest's error watcher would record as an error. The scenario mutes the
# titles of the failed units for its run, waits until the watcher has handled the journal up to a sentinel report, and checks
# that the store is as it was.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

NOW_DROPIN_DIR=/run/systemd/system/vekrona-update-now.service.d
UPDATE_SCRIPT=/run/vekrona-e2e-update-run
# The titles the watcher gives the failures: the update unit, the transient unit that runs the client (run-u<N> in older systemd,
# run-p<PID>-i<N> since), and systemd's own line about the unit.
UPDATE_UNIT_TITLE='vekrona-update-now.service failed'
UPDATE_START_TITLE='systemd: Failed to start vekrona-update-now.service'
MUTED_TITLE='^((vekrona-update-now|run-(u[0-9]+|p[0-9]+-i[0-9]+))\.service failed|systemd: Failed to start vekrona-update-now\.service - .*)$'
MUTE_FILE='$HOME/.config/vekrona/errors-mute'
SENTINEL="$(sentinel_title)"
# A deadline for a client that never sees the end of the unit, not a pause.
CLIENT_DEADLINE_SEC=60

# Every restore step runs, whatever an earlier one did. A scenario that passed fails with the first failed step.
restore_failed=0
restore() {
  local status=0
  "$@" || status=$?
  [[ "$restore_failed" -ne 0 ]] || restore_failed=$status
}

mute_unit_failures() { vekrona-dev run bash -c "mkdir -p \$(dirname $MUTE_FILE) && printf '%s\n' \"\$1\" >>$MUTE_FILE" _ "$MUTED_TITLE"; }
unmute_unit_failures() {
  vekrona-dev run bash -c "set -euo pipefail; [[ ! -e $MUTE_FILE ]] || { { grep -vxF \"\$1\" $MUTE_FILE || [[ \$? -eq 1 ]]; } >$MUTE_FILE.new; mv $MUTE_FILE.new $MUTE_FILE; }" _ "$MUTED_TITLE"
}
cleanup() {
  local scenario_status=$?
  restore unmute_unit_failures
  restore error_titled_remove "$SENTINEL"
  restore vekrona-dev run sudo rm -rf "$NOW_DROPIN_DIR" "$UPDATE_SCRIPT"
  restore vekrona-dev run sudo systemctl daemon-reload
  restore vekrona-dev run sudo systemctl reset-failed vekrona-update-now.service
  [[ "$scenario_status" -ne 0 ]] || exit "$restore_failed"
}
trap cleanup EXIT

# Replaces the unit's update with a script that prints, re-executes PID 1 as systemd's scriptlets do, prints and exits with $1.
install_update_that_reexecs_and_exits() {
  vekrona-dev run sudo bash -c '
set -euo pipefail
printf "%s\n" "echo update-before-reexec" "systemctl daemon-reexec" "echo update-after-reexec" "exit $1" >"$2"
install -d "$3"
printf "[Service]\nExecStart=\nExecStart=/usr/bin/bash %s\n" "$2" >"$3/zz-e2e.conf"
systemctl daemon-reload
' _ "$1" "$UPDATE_SCRIPT" "$NOW_DROPIN_DIR"
}

# polkit lets only an administrator at the machine start the unit, and the ssh login is remote, so the client runs from
# a systemd user service, like the toast and the launcher run it. Prints its output and then its exit status.
run_client() {
  local status=0 out
  out="$(vekrona-dev run systemd-run --user --pipe --wait --collect --quiet timeout "$CLIENT_DEADLINE_SEC" vekrona-update now 2>&1)" || status=$?
  printf '%s\n%s\n' "$out" "$status"
}

vekrona-dev session
# A muted failure still marks an earlier record of its title muted, and the update unit's titles are the same in every run, so
# records an earlier run left (before the mutes, or a run killed before its cleanup) would change: they go first.
error_titled_remove "$UPDATE_UNIT_TITLE"
error_titled_remove "$UPDATE_START_TITLE"
store_before="$(error_store_without "$SENTINEL")"
mute_unit_failures

install_update_that_reexecs_and_exits 0
result="$(run_client)"
[[ "${result##*$'\n'}" -eq 0 ]] || die "vekrona-update did not end with the unit's success: $result"
for line in update-before-reexec update-after-reexec; do
  grep -qx "$line" <<<"$result" || die "vekrona-update did not show '$line': $result"
done
log "ok: vekrona-update shows the whole run and succeeds although the run re-executed systemd"

install_update_that_reexecs_and_exits 1
result="$(run_client)"
status="${result##*$'\n'}"
[[ "$status" -ne 0 && "$status" -ne 124 ]] || die "vekrona-update did not fail with the unit: $result"
grep -qx update-after-reexec <<<"$result" || die "vekrona-update did not show the failed run's last line: $result"
log "ok: vekrona-update fails when the run that re-executed systemd failed"

error_watcher_sync "$SENTINEL"
store_after="$(error_store_without "$SENTINEL")"
[[ "$store_after" == "$store_before" ]] || die "the failed units must leave the error store unchanged, but it changed: $(diff <(echo "$store_before") <(echo "$store_after"))"
log "ok: the deliberate failure leaves the error store unchanged"
