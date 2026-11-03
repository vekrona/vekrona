#!/usr/bin/env bash
# A reboot stops the Sway session's apps while Sway still serves them (vekrona-session-teardown), so none of them fails on a
# broken display: the previous boot's journal shows their units stopped before the session's scope began to stop, and the
# error watcher records nothing for them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

BOOT_TIMEOUT_SEC=240
# Units whose absence from the session says the scenario cannot prove anything, and units that run only on some machines
# (sealert comes with setroubleshoot's autostart entry).
REQUIRED_UNITS=(vekrona-shell.service vekrona-cliphist.service)
OPTIONAL_UNITS=(xdg-desktop-portal-gtk.service 'app-sealert*')
# The titles under which the watcher records a failure of these apps.
APP_TITLES='sealert|xdg-desktop-portal-gtk|cliphist|vekrona-shell'
SENTINEL="$(sentinel_title)"
forget_sentinels() { error_titled_remove "$SENTINEL"; }
trap 'run_cleanups forget_sentinels' EXIT

running_units() {
  vekrona-dev sh bash -c 'systemctl --user list-units --state=active --plain --no-legend --no-pager "$@" | awk "{ print \$1 }"' _ "${REQUIRED_UNITS[@]}" "${OPTIONAL_UNITS[@]}"
}

vekrona-dev session
vekrona-dev sh systemctl --user is-active --quiet vekrona-session-teardown.service || die "vekrona-session-teardown.service does not run, so there is no teardown to prove"
mapfile -t units < <(running_units)
for required in "${REQUIRED_UNITS[@]}"; do
  [[ " ${units[*]} " == *" $required "* ]] || die "$required does not run in the session, so its teardown cannot be shown (running: ${units[*]})"
done
log "units to stop before the session: ${units[*]}"

sway_session="$(sway_session_id)"
[[ -n "$sway_session" ]] || die "sway runs in no login session, so there is no scope to compare with"
error_watcher_sync "$SENTINEL"
store_before="$(error_store_without "$SENTINEL")"

marker="e2e-session-teardown reboot requested $RANDOM$RANDOM"
vekrona-dev run logger -t e2e-session-teardown "$marker"
previous_boot="$(boot_id)"
vekrona-dev reboot
booted_again "$previous_boot" || die "the guest did not boot again"
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- greeter_up

# The matches of one field are alternatives, and + separates alternatives of different fields: the marker, the units' stops
# and the scope's stop.
matches=(SYSLOG_IDENTIFIER=e2e-session-teardown +)
for unit in "${units[@]}"; do
  matches+=("USER_UNIT=$unit")
done
matches+=(+ "UNIT=session-$sway_session.scope")
vekrona-dev run sudo journalctl -b -1 --no-pager -o json "${matches[@]}" | python3 -I "$ROOT/tests/e2e/session-teardown-order.py" "$marker" "$sway_session" "${units[@]}"
log "ok: the session's units stopped before its scope began to stop"

vekrona-dev session
# The watcher replays the journal from its cursor, which holds the previous boot's last lines, before it reaches the sentinel.
error_watcher_sync "$SENTINEL after the reboot"
store_after="$(error_store_without "$SENTINEL")"
new_records="$(comm -13 <(sort <<<"$store_before") <(sort <<<"$store_after") | { grep -E "$APP_TITLES" || [[ $? -eq 1 ]]; })"
[[ -z "$new_records" ]] || die "the reboot must leave no error record for $APP_TITLES, but left: $new_records"
log "ok: the error store holds no new record for the session's apps"
