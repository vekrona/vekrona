#!/usr/bin/env bash
# The right password unlocks even when the lock screen cannot start vekrona-session-hint: the hint is never what the
# unlock waits for, and a helper that cannot start is logged as a QML error, which the error pipeline records. A drop-in
# gives the locker a PATH without ~/.local/bin, where stage 50 links the helper.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PASSWORD=vekrona
DROP_IN_DIR='.config/systemd/user/vekrona-lock.service.d'
DROP_IN="$DROP_IN_DIR/e2e-no-session-hint.conf"

restore_path() { vekrona-dev run bash -c 'rm -f ~/"$1" && rmdir ~/"$2" && systemctl --user daemon-reload' _ "$DROP_IN" "$DROP_IN_DIR"; }
lock_log_since_matching() {
  local log
  log="$(vekrona-dev run journalctl --user -t vekrona-lock --since "@$1" --no-pager -o cat)" || abort "cannot read the vekrona-lock log since $1"
  grep -E "$2" <<<"$log" || [[ $? -eq 1 ]]
}

vekrona-dev session
started="$(vekrona-dev run date +%s)"
vekrona-dev run bash -c 'mkdir -p ~/"$1" && printf "[Service]\nEnvironment=PATH=/usr/bin\n" >~/"$2" && systemctl --user daemon-reload' \
  _ "$DROP_IN_DIR" "$DROP_IN"
trap restore_path EXIT

vekrona-dev sh vekrona-lock start
lock_active || die "vekrona-lock returned before the locker confirmed the lock, although only the hint helper is missing"
[[ -n "$(lock_log_since_matching "$started" 'Process failed to start.*vekrona-session-hint')" ]] \
  || die "the locker started vekrona-session-hint, so the scenario proves nothing"
log "ok: the lock screen locks although it cannot start the hint helper"

vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive \
  || die "the right password left the screen locked because vekrona-session-hint could not start"
log "ok: the right password unlocks without the hint helper"

for step in yes no; do
  [[ -n "$(lock_log_since_matching "$started" "ERROR.*vekrona-session-hint locked $step could not start")" ]] \
    || die "the locker did not log that it could not start vekrona-session-hint locked $step"
done
# The failed start ends the step at once; the deadline is for a hint helper that hangs.
[[ -z "$(lock_log_since_matching "$started" 'did not end within')" ]] \
  || die "the locker waited for its deadline on a hint helper that never started"
log "ok: both failed starts are logged as QML errors, and the unlock did not wait for the deadline"

