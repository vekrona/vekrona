#!/usr/bin/env bash
set -euo pipefail

# logind is the only sleep authority: swayidle sets the IdleHint, logind's IdleAction suspends, and a caffeine
# inhibitor stops it. The timers are shortened with drop-ins under /run, and the suspend itself is replaced by
# /usr/bin/true so the VM keeps running; logind still emits PrepareForSleep, which is what the scenario waits on.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
IDLEHINT_SEC=5
IDLE_ACTION_SEC=5
# A deadline, not an ordering: the idle hint plus IdleActionSec is 10 s, so a suspend that is going to happen
# is long due after this.
NO_SUSPEND_WINDOW_SEC=45

LOGIND_DROPIN_DIR=/run/systemd/logind.conf.d
SUSPEND_DROPIN_DIR=/run/systemd/system/systemd-suspend.service.d
IDLE_UNIT_DROPIN_SUBDIR=systemd/user/vekrona-idle.service.d
MONITOR_PREFIX=/tmp/vekrona-idle-suspend
NEGATIVE_OUT="$MONITOR_PREFIX-negative.out"
NEGATIVE_STATUS="$MONITOR_PREFIX-negative.status"
POSITIVE_OUT="$MONITOR_PREFIX-positive.out"

# One JSON line per PrepareForSleep(true); the monitor exits after the first.
monitor_command() {
  printf 'timeout %s busctl --system --json=short --limit-messages=1 --match=%q monitor' "$1" \
    "type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'"
}

cleanup() {
  vekrona-dev sh vekrona-caffeine off >/dev/null
  vekrona-dev run sudo rm -rf "$LOGIND_DROPIN_DIR/zz-test.conf" "$SUSPEND_DROPIN_DIR" "$NEGATIVE_OUT" "$NEGATIVE_STATUS" "$POSITIVE_OUT"
  vekrona-dev run sudo systemctl daemon-reload
  vekrona-dev run sudo systemctl reload systemd-logind
  vekrona-dev sh bash -c 'rm -rf "$XDG_RUNTIME_DIR/$1" && systemctl --user daemon-reload && systemctl --user restart vekrona-idle.service' _ "$IDLE_UNIT_DROPIN_SUBDIR"
}

unit_active() { [[ "$(vekrona-dev sh systemctl --user is-active "$1")" == active ]]; }
file_has_signal() { vekrona-dev run grep -q '"data":\[true\]' "$1"; }
status_written() { vekrona-dev run test -s "$1"; }
export -f unit_active file_has_signal status_written

vekrona-dev session
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unit_active vekrona-idle.service

# The installed drop-in is live in the running logind (stage 40 reloads it), before any test override.
[[ "$(vekrona-dev run loginctl show-session -p IdleAction --value)" == suspend ]] || die "logind does not run with IdleAction=suspend: the drop-in is not loaded"
[[ "$(vekrona-dev run loginctl show-session -p IdleActionUSec --value)" == 25min ]] || die "logind's IdleActionSec is not 25min"
log "ok: the running logind has IdleAction=suspend after 25min"

trap cleanup EXIT

vekrona-dev run sudo install -d "$SUSPEND_DROPIN_DIR" "$LOGIND_DROPIN_DIR"
vekrona-dev run sudo bash -c 'printf "[Service]\nExecStart=\nExecStart=/usr/bin/true\n" >"$1/zz-test.conf"' _ "$SUSPEND_DROPIN_DIR"
vekrona-dev run sudo bash -c 'printf "[Login]\nIdleActionSec=%ss\n" "$2" >"$1/zz-test.conf"' _ "$LOGIND_DROPIN_DIR" "$IDLE_ACTION_SEC"
vekrona-dev run sudo systemctl daemon-reload
vekrona-dev run sudo systemctl reload systemd-logind

# The unit's own ExecStart with only the idle hint shortened, so the scenario fails when the unit has no idlehint.
vekrona-dev sh bash -c '
  set -euo pipefail
  dir="$XDG_RUNTIME_DIR/$1"
  exec_start="$(systemctl --user cat vekrona-idle.service | grep "^ExecStart=")"
  shortened="${exec_start/idlehint 300/idlehint $2}"
  [[ "$shortened" != "$exec_start" ]] || { echo "vekrona-idle.service has no idlehint 300" >&2; exit 1; }
  mkdir -p "$dir"
  printf "[Service]\nExecStart=\n%s\n" "$shortened" >"$dir/zz-test.conf"
' _ "$IDLE_UNIT_DROPIN_SUBDIR" "$IDLEHINT_SEC"

# Both monitors run before anything can go idle, so no signal is missed. The negative one is the deadline for
# "no suspend while caffeine is held"; the positive one outlives it and catches the suspend after caffeine ends.
vekrona-dev spawn --root "$NEGATIVE_OUT" -- bash -c "$(monitor_command "$NO_SUSPEND_WINDOW_SEC"); echo \$? >$NEGATIVE_STATUS"
vekrona-dev spawn --root "$POSITIVE_OUT" -- bash -c "$(monitor_command "$((NO_SUSPEND_WINDOW_SEC + STEP_TIMEOUT_SEC))")"

vekrona-dev sh vekrona-caffeine 1h
vekrona-dev sh systemctl --user daemon-reload
vekrona-dev sh systemctl --user restart vekrona-idle.service

vekrona-dev until --timeout "$((NO_SUSPEND_WINDOW_SEC + STEP_TIMEOUT_SEC))" -- status_written "$NEGATIVE_STATUS"
[[ "$(vekrona-dev run cat "$NEGATIVE_STATUS")" == 124 ]] || die "logind suspended an idle session while caffeine held a sleep:idle inhibitor"
log "ok: no suspend for ${NO_SUSPEND_WINDOW_SEC}s of idleness while caffeine is on"

vekrona-dev sh vekrona-caffeine off
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- file_has_signal "$POSITIVE_OUT"
log "ok: logind suspends the idle session once caffeine is off"

vekrona-dev session
