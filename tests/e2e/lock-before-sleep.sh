#!/usr/bin/env bash
# logind cannot cancel a suspend that has begun, and swayidle's before-sleep inhibitor is only a delay lock. So the machine
# suspends through vekrona-suspend (lock first), and a screen that cannot be locked holds a block lock on sleep until a lock
# succeeds: the session stays up, nothing suspends, and the failure is in the error list. The suspend itself is replaced by
# /usr/bin/true (fake_suspend); logind still emits PrepareForSleep, which the monitor below catches.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
SUSPEND_MONITOR_SEC=120
GUEST_PASSWORD=vekrona
SUSPEND_OUT=/tmp/vekrona-lock-before-sleep.out
SUSPEND_RUNNER=/tmp/vekrona-lock-before-sleep.sh
SUSPEND_STATUS=/tmp/vekrona-lock-before-sleep.status
BROKEN_LOCKER_DIR='$XDG_RUNTIME_DIR/systemd/user/vekrona-lock.service.d'

# What logind consults before it acts: the block locks it holds, which sleep, handle-lid-switch and handle-suspend-key name.
blocks() {
  local blocked
  blocked="$(vekrona-dev run busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager BlockInhibited)" \
    || abort "cannot read the block locks logind holds"
  [[ "$blocked" == *"$1"* ]]
}
sleep_blocked() { blocks sleep; }
sleep_free() { absent sleep_blocked; }
suspend_returned() { vekrona-dev run test -e "$SUSPEND_STATUS"; }
recorded_failure() { vekrona-dev sh vekrona-error list | grep -q 'cannot start the lock screen'; }
suspended() { vekrona-dev run test -s "$SUSPEND_OUT"; }
export -f blocks sleep_blocked sleep_free suspend_returned recorded_failure suspended
export SUSPEND_STATUS

break_locker() {
  vekrona-dev sh bash -c "dir=\"$BROKEN_LOCKER_DIR\"; mkdir -p \"\$dir\" && printf '[Service]\nExecStart=\nExecStart=/usr/bin/false\n' >\"\$dir/zz-test.conf\" && systemctl --user daemon-reload"
}
repair_locker() {
  vekrona-dev sh bash -c "rm -rf \"$BROKEN_LOCKER_DIR\" && systemctl --user daemon-reload"
}
# Watches logind for the next suspend; $SUSPEND_OUT holds its PrepareForSleep signal once there is one.
watch_for_suspend() {
  vekrona-dev run sudo rm -f "$SUSPEND_OUT"
  vekrona-dev spawn --root "$SUSPEND_OUT" -- timeout "$SUSPEND_MONITOR_SEC" busctl --system --json=short --limit-messages=1 \
    --match="type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" monitor
}
# Runs vekrona-suspend as a child of Sway, as the lid does (the launcher starts it as a transient user unit instead, see TODO.md), and sets SUSPEND_STATUS_CODE to its exit status. The ssh
# session vekrona-dev works through is no active session: polkit asks it for a password before logind suspends, which nobody answers.
suspend_from_sway() {
  vekrona-dev run bash -c 'printf "#!/bin/sh\nvekrona-suspend now\necho \$? >%s\n" "$2" >"$1"; chmod +x "$1"; rm -f "$2"' _ "$SUSPEND_RUNNER" "$SUSPEND_STATUS"
  vekrona-dev sh swaymsg exec "$SUSPEND_RUNNER" >/dev/null
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- suspend_returned
  SUSPEND_STATUS_CODE="$(vekrona-dev run cat "$SUSPEND_STATUS")"
}
unlock_screen() {
  vekrona-dev type --enter "$GUEST_PASSWORD"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive
}

remove_suspend_output() { vekrona-dev run sudo rm -f "$SUSPEND_OUT" "$SUSPEND_RUNNER" "$SUSPEND_STATUS"; }
# A lock left running or a broken locker would fail the next scenario; the real suspend goes first.
trap 'run_cleanups real_suspend repair_locker "vekrona-dev sh systemctl --user stop vekrona-lock-guard.service" remove_suspend_output "vekrona-dev session"' EXIT

vekrona-dev session
fake_suspend
sleep_free || die "a block lock on sleep is held before the scenario starts"

blocks handle-lid-switch || die "logind would handle the lid itself: nothing holds handle-lid-switch while the Sway session runs"
blocks handle-suspend-key || die "logind would suspend on the sleep key itself, without locking: nothing holds handle-suspend-key"
log "ok: logind leaves the lid and the sleep key to Sway"

watch_for_suspend
suspend_from_sway
[[ "$SUSPEND_STATUS_CODE" == 0 ]] || die "vekrona-suspend failed with status $SUSPEND_STATUS_CODE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sleep_signalled "$SUSPEND_OUT"
lock_active || die "the machine went to sleep before the screen was locked"
sleep_free || die "the lock is up, but the block on sleep is still held"
log "ok: vekrona-suspend locks, releases the block and suspends"

unlock_screen
watch_for_suspend
vekrona-dev key sleep
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sleep_signalled "$SUSPEND_OUT"
lock_active || die "the sleep key suspended the machine before the screen was locked"
log "ok: the sleep key locks first, as vekrona-suspend does"

unlock_screen
watch_for_suspend
break_locker
suspend_from_sway
((SUSPEND_STATUS_CODE != 0)) || die "vekrona-suspend succeeded although the locker cannot start"
sway_running || die "a failed lock ended the session"
sleep_blocked || die "the lock failed and nothing blocks the next suspend: logind would accept it"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- recorded_failure
absent suspended || die "the machine suspended although the screen is unlocked"
log "ok: a failed lock keeps the session, blocks sleep and is in the error list"

repair_locker
vekrona-dev sh vekrona-lock start
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sleep_free
log "ok: a lock that succeeds releases the block"

unlock_screen
