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
stub systemctl 'echo "$*" >> "$SCRATCH/logs/systemctl"
case "$2" in
  is-active) exit 3;;
  start) if [[ -n "${START_ERR:-}" ]]; then echo "$START_ERR" >&2; exit 1; fi;;
  *) exit 99;;
esac'
stub systemd-run 'echo "$*" >> "$SCRATCH/logs/systemd-run"
echo "Failed to start transient service unit: Unit vekrona-lock.service was already loaded or has a fragment file." >&2
exit 1'
stub notify-send 'echo "$*" >> "$SCRATCH/logs/notify"
[[ "${NOTIFY_FAIL:-}" != 1 ]] || exit 1'

run_lock() {
  rm -rf "$logs"
  mkdir -p "$logs"
  rc=0
  PATH="$stubs:$PATH" "$tool" >/dev/null 2>"$scratch/stderr" || rc=$?
}
expect_rc() { [[ "$rc" == "$1" ]] || die "$2: expected exit $1, got $rc: $(cat "$scratch/stderr")"; }
logged() { [[ -e "$logs/$1" ]]; }

run_lock
expect_rc 0 "a trigger while the locker is still starting must succeed"
! logged notify || die "a trigger while the locker is still starting must not raise a notification: $(cat "$logs/notify")"
! logged systemd-run || die "the locker must be started through its unit, not a transient one that a running copy blocks"
grep -qx -- '--user start vekrona-lock.service' "$logs/systemctl" || die "the lock must start vekrona-lock.service in the user manager"
log "ok: a second trigger while the locker is activating joins it, silently"

START_ERR="Job for vekrona-lock.service failed because a timeout was exceeded." run_lock
expect_rc 1 "a locker that never confirms the lock must fail"
grep -q 'timeout was exceeded' "$scratch/stderr" || die "the failure must be printed: $(cat "$scratch/stderr")"
logged notify || die "a locker that cannot start must raise a notification"
grep -q -- '-u critical' "$logs/notify" || die "the notification must be critical: $(cat "$logs/notify")"
grep -q 'timeout was exceeded' "$logs/notify" || die "the notification must carry the reason: $(cat "$logs/notify")"
log "ok: a start failure is printed and notified as critical"

START_ERR="boom" NOTIFY_FAIL=1 run_lock
expect_rc 1 "a failure whose notification also fails"
grep -q 'notify-send failed' "$scratch/stderr" || die "a failed notification must be reported on stderr: $(cat "$scratch/stderr")"
log "ok: a failing notify-send does not hide the start failure"
