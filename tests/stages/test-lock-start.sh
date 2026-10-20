#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-lock"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch"
logs="$scratch/logs"
stubs="$scratch/stubs"
mkdir -p "$stubs" "$logs"

stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }

# The locker unit is always "activating" here (a start in progress or an auto-restart): is-active says no,
# a second transient unit of that name is refused, and `start` joins the job in progress.
# $3 is the unit: START_ERR and START_FAILS break the locker, GUARD_ERR the suspend block, GUARD_STOP_ERR its release.
stub systemctl 'echo "$*" >> "$SCRATCH/logs/systemctl"
case "$2 $3" in
  "is-active "*) exit 3;;
  "start vekrona-lock-guard.service")
    if [[ -n "${GUARD_ERR:-}" ]]; then echo "$GUARD_ERR" >&2; exit 1; fi;;
  "stop vekrona-lock-guard.service")
    if [[ -n "${GUARD_STOP_ERR:-}" ]]; then echo "$GUARD_STOP_ERR" >&2; exit 1; fi;;
  "start vekrona-lock.service")
    if [[ -n "${START_ERR:-}" ]]; then echo "$START_ERR" >&2; exit 1; fi
    if [[ -n "${START_FAILS:-}" ]]; then
      starts="$(cat "$SCRATCH/starts" 2>/dev/null || echo 0)"
      echo $((starts + 1)) > "$SCRATCH/starts"
      if ((starts < START_FAILS)); then echo "Job for vekrona-lock.service failed." >&2; exit 1; fi
    fi;;
  *) exit 99;;
esac'
stub systemd-run 'echo "$*" >> "$SCRATCH/logs/systemd-run"
echo "Failed to start transient service unit: Unit vekrona-lock.service was already loaded or has a fragment file." >&2
exit 1'
stub notify-send 'echo "$*" >> "$SCRATCH/logs/notify"
[[ "${NOTIFY_FAIL:-}" != 1 ]] || exit 1'
stub swaymsg 'echo "$*" >> "$SCRATCH/logs/swaymsg"
[[ "${SWAYMSG_FAIL:-}" != 1 ]] || exit 1'
stub reporter 'echo "$*" >> "$SCRATCH/logs/reported"
[[ "${REPORT_FAIL:-}" != 1 ]] || exit 1'
export VEKRONA_ERROR_REPORTER="$stubs/reporter"

run_lock() {
  rm -rf "$logs" "$scratch/starts"
  mkdir -p "$logs"
  rc=0
  PATH="$stubs:$PATH" "$tool" "$@" >/dev/null 2>"$scratch/stderr" || rc=$?
}
expect_rc() { [[ "$rc" == "$1" ]] || die "$2: expected exit $1, got $rc: $(cat "$scratch/stderr")"; }
logged() { [[ -e "$logs/$1" ]]; }

run_lock start
expect_rc 0 "a trigger while the locker is still starting must succeed"
! logged notify || die "a trigger while the locker is still starting must not raise a notification: $(cat "$logs/notify")"
! logged reported || die "a trigger while the locker is still starting must not report an error: $(cat "$logs/reported")"
! logged systemd-run || die "the locker must be started through its unit, not a transient one that a running copy blocks"
grep -qx -- '--user start vekrona-lock.service' "$logs/systemctl" || die "the lock must start vekrona-lock.service in the user manager"
log "ok: a second trigger while the locker is activating joins it, silently"

START_ERR="Job for vekrona-lock.service failed because a timeout was exceeded." run_lock start
expect_rc 1 "a locker that never confirms the lock must fail"
grep -q 'timeout was exceeded' "$scratch/stderr" || die "the failure must be printed: $(cat "$scratch/stderr")"
[[ "$(wc -l < "$logs/reported")" == 1 ]] || die "a locker that cannot start must report exactly one error: $(cat "$logs/reported" 2>&1)"
grep -q 'timeout was exceeded' "$logs/reported" || die "the report must carry the reason: $(cat "$logs/reported")"
! logged notify || die "a recorded failure needs no toast, the robot shows the record: $(cat "$logs/notify")"
log "ok: a start failure is printed and reported once, without a toast"

START_ERR="boom" REPORT_FAIL=1 run_lock start
expect_rc 1 "a failure that cannot be reported"
grep -q 'failed to report' "$scratch/stderr" || die "a failed report must be named on stderr: $(cat "$scratch/stderr")"
[[ "$(wc -l < "$logs/notify")" == 1 ]] || die "an unrecorded failure must be toasted once: $(cat "$logs/notify" 2>&1)"
grep -q -- '-u critical' "$logs/notify" || die "the toast must be critical: $(cat "$logs/notify")"
grep -q 'boom' "$logs/notify" || die "the toast must carry the reason: $(cat "$logs/notify")"
log "ok: a failure that cannot be reported is toasted instead"

START_ERR="boom" REPORT_FAIL=1 NOTIFY_FAIL=1 run_lock start
expect_rc 1 "a failure that can neither be reported nor toasted"
grep -q 'failed to show this error as a notification' "$scratch/stderr" || die "a failed toast must be named on stderr: $(cat "$scratch/stderr")"
log "ok: a failing notify-send does not hide the start failure"

# Every lock attempt holds the suspend block first, and only a locked screen releases it.
GUARD_START='--user start vekrona-lock-guard.service'
LOCK_START='--user start vekrona-lock.service'
GUARD_STOP='--user stop vekrona-lock-guard.service'
guard_held() { grep -qxF -- "$GUARD_START" "$logs/systemctl" && ! grep -qxF -- "$GUARD_STOP" "$logs/systemctl"; }

run_lock start
expect_rc 0 "a lock"
mapfile -t calls <"$logs/systemctl"
[[ "${calls[*]}" == "$GUARD_START $LOCK_START $GUARD_STOP" ]] || die "a lock must hold the suspend block, lock, then release it: ${calls[*]}"
log "ok: a lock holds the suspend block until the screen is locked, then releases it"

START_ERR="Job for vekrona-lock.service failed." run_lock start
expect_rc 1 "a lock that fails"
guard_held || die "a failed lock must leave the suspend block held, or the machine suspends unlocked: $(cat "$logs/systemctl")"
! logged swaymsg || die "a failed lock must leave the session running: $(cat "$logs/swaymsg")"
grep -q 'suspend stays blocked' "$logs/reported" || die "the report must say that the machine stays awake: $(cat "$logs/reported")"
log "ok: a failed lock keeps suspend blocked, keeps the session and says so"

GUARD_ERR="Failed to start vekrona-lock-guard.service" run_lock start
expect_rc 1 "a suspend block that cannot be held"
! grep -qxF -- "$LOCK_START" "$logs/systemctl" || die "without the suspend block the lock must not even be tried"
grep -q 'cannot block suspend' "$logs/reported" || die "a block that cannot be held must be reported: $(cat "$logs/reported" 2>&1)"
log "ok: a suspend block that cannot be held is reported"

GUARD_STOP_ERR="Failed to stop vekrona-lock-guard.service" run_lock start
expect_rc 1 "a suspend block that will not release"
grep -q 'would not stop' "$logs/reported" || die "a block that will not release must be reported: $(cat "$logs/reported" 2>&1)"
log "ok: a suspend block that will not release is reported"

START_FAILS=2 run_lock --before-sleep
expect_rc 0 "a locker that starts on the third try"
[[ "$(<"$scratch/starts")" == 3 ]] || die "before-sleep must retry a failed start: $(<"$scratch/starts") starts"
grep -qxF -- "$GUARD_STOP" "$logs/systemctl" || die "a screen that got locked must release the suspend block"
log "ok: before sleep a failed start is retried, and a lock releases the block"

START_ERR="Job for vekrona-lock.service failed because a timeout was exceeded." run_lock --before-sleep
expect_rc 1 "a screen that cannot be locked before suspend"
guard_held || die "a failed lock before suspend must leave the block held for the next suspend: $(cat "$logs/systemctl")"
! logged swaymsg || die "the session must stay up: $(cat "$logs/swaymsg")"
[[ "$(wc -l < "$logs/reported")" == 1 ]] || die "the failure must be reported exactly once: $(cat "$logs/reported" 2>&1)"
grep -q 'timeout was exceeded' "$logs/reported" || die "the report must carry the reason: $(cat "$logs/reported")"
log "ok: before sleep a locker that never comes up is reported once and keeps later suspends blocked"

run_lock --bogus
expect_rc 2 "an unknown option"
log "ok: an unknown option is refused"
