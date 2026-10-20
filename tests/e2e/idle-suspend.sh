#!/usr/bin/env bash
set -euo pipefail

# logind is the only sleep authority: swayidle sets the IdleHint, logind's IdleAction suspends, and a caffeine
# inhibitor stops it. The timers are shortened with drop-ins under /run, and the suspend itself is replaced by
# /usr/bin/true so the VM keeps running; logind still emits PrepareForSleep, which is what the scenario waits on.
# logind arms its idle timer only when it starts, so a changed IdleActionSec needs a restart, not a reload.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
IDLEHINT_SEC=5
IDLE_ACTION_SEC=5
# A deadline, not an ordering: the idle hint plus IdleActionSec is 10 s, so a suspend that is going to happen
# is long due after this.
NO_SUSPEND_WINDOW_SEC=45

LOGIND_DROPIN_DIR=/run/systemd/logind.conf.d
MONITOR_PREFIX=/tmp/vekrona-idle-suspend
NEGATIVE_OUT="$MONITOR_PREFIX-negative.out"
NEGATIVE_STATUS="$MONITOR_PREFIX-negative.status"
POSITIVE_OUT="$MONITOR_PREFIX-positive.out"

# One JSON line per PrepareForSleep(true); the monitor exits after the first.
monitor_command() {
  printf 'timeout %s busctl --system --json=short --limit-messages=1 --match=%q monitor' "$1" \
    "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"
}

remove_test_files() { vekrona-dev run sudo rm -rf "$LOGIND_DROPIN_DIR/zz-test.conf" "$NEGATIVE_OUT" "$NEGATIVE_STATUS" "$POSITIVE_OUT"; }

# The pam_env line of sshd goes first, whatever else fails: left behind, it refuses every ssh login once its file is gone.
cleanup() {
  run_cleanups ssh_sessions_unconfigure 'vekrona-dev sh vekrona-caffeine off >/dev/null' remove_test_files real_suspend \
    'vekrona-dev run sudo systemctl restart systemd-logind' restore_idlehint ssh_sessions_relogin
}

unit_active() { [[ "$(vekrona-dev sh systemctl --user is-active "$1")" == active ]]; }
status_written() { vekrona-dev run test -s "$1"; }
export -f unit_active status_written

vekrona-dev session
trap cleanup EXIT
ssh_sessions_background
# The idle service picks the session to set the idle hint on when it starts, so it starts after the ssh session left.
vekrona-dev sh systemctl --user restart vekrona-idle.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unit_active vekrona-idle.service

# The installed drop-in is live in the running logind (stage 40 restarts logind for it), before any test override.
[[ "$(vekrona-dev run loginctl show-session -p IdleAction --value)" == suspend ]] || die "logind does not run with IdleAction=suspend: the drop-in is not loaded"
[[ "$(vekrona-dev run loginctl show-session -p IdleActionUSec --value)" == 25min ]] || die "logind's IdleActionSec is not 25min"
log "ok: the running logind has IdleAction=suspend after 25min"

fake_suspend
vekrona-dev run sudo install -d "$LOGIND_DROPIN_DIR"
vekrona-dev run sudo bash -c 'printf "[Login]\nIdleActionSec=%ss\n" "$2" >"$1/zz-test.conf"' _ "$LOGIND_DROPIN_DIR" "$IDLE_ACTION_SEC"
vekrona-dev run sudo systemctl restart systemd-logind

shorten_idlehint "$IDLEHINT_SEC"

# Both monitors run before anything can go idle, so no signal is missed. The negative one is the deadline for
# "no suspend while caffeine is held"; the positive one outlives it and catches the suspend after caffeine ends.
vekrona-dev spawn --root "$NEGATIVE_OUT" -- bash -c "$(monitor_command "$NO_SUSPEND_WINDOW_SEC"); echo \$? >$NEGATIVE_STATUS"
vekrona-dev spawn --root "$POSITIVE_OUT" -- bash -c "$(monitor_command "$((NO_SUSPEND_WINDOW_SEC + STEP_TIMEOUT_SEC))")"

vekrona-dev sh vekrona-caffeine for 1h
vekrona-dev sh systemctl --user daemon-reload
vekrona-dev sh systemctl --user restart vekrona-idle.service

vekrona-dev until --timeout "$((NO_SUSPEND_WINDOW_SEC + STEP_TIMEOUT_SEC))" -- status_written "$NEGATIVE_STATUS"
[[ "$(vekrona-dev run cat "$NEGATIVE_STATUS")" == 124 ]] || die "logind suspended an idle session while caffeine held a sleep inhibitor"
log "ok: no suspend for ${NO_SUSPEND_WINDOW_SEC}s of idleness while caffeine is on"

vekrona-dev sh vekrona-caffeine off
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sleep_signalled "$POSITIVE_OUT"
log "ok: logind suspends the idle session once caffeine is off"
