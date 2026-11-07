#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/installed"

cat > "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
cat > "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
[[ "${STUB_BREAK:-}" != "$1" ]] || { echo "systemctl: cannot reach the bus" >&2; exit 5; }
if [[ "$1" == is-active ]]; then
  echo "${STUB_ACTIVE:-inactive}"
  [[ "${STUB_ACTIVE:-inactive}" == active ]] || exit 3
fi
if [[ "$1" == is-failed ]]; then
  echo "${STUB_FAILED:-inactive}"
  [[ "${STUB_FAILED:-inactive}" == failed ]] || exit "${STUB_NOT_FAILED_STATUS:-1}"
fi
F
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" VEKRONA_SYSTEMD_UNIT_DIR="$work/installed"

printf '[Unit]\nDescription=one\n' > "$work/vekrona-x.service"
reloads() { grep -c '^systemctl daemon-reload$' "$STUB_LOG" || true; }

: > "$STUB_LOG"
ensure_system_unit_file "$work/vekrona-x.service" 2>/dev/null
cmp -s "$work/vekrona-x.service" "$work/installed/vekrona-x.service" || die "the unit file was not installed under its own name"
[[ "$(stat -c %a "$work/installed/vekrona-x.service")" == 644 ]] || die "unit file mode is not 0644"
[[ "$(reloads)" -eq 1 ]] || die "a new unit file did not reload systemd"
log "ok: a new unit file is installed and systemd reloads once"

: > "$STUB_LOG"
ensure_system_unit_file "$work/vekrona-x.service" 2>/dev/null
[[ "$(reloads)" -eq 0 ]] || die "an unchanged unit file reloaded systemd"
log "ok: an unchanged unit file does not reload systemd"

printf '[Unit]\nDescription=two\n' > "$work/vekrona-x.service"
ensure_system_unit_file "$work/vekrona-x.service" 2>/dev/null
cmp -s "$work/vekrona-x.service" "$work/installed/vekrona-x.service" || die "a changed unit file was not replaced"
[[ "$(reloads)" -eq 1 ]] || die "a changed unit file did not reload systemd"
log "ok: a changed unit file is replaced and systemd reloads"

chmod 600 "$work/installed/vekrona-x.service"
: > "$STUB_LOG"
ensure_system_unit_file "$work/vekrona-x.service" 2>/dev/null
[[ "$(stat -c %a "$work/installed/vekrona-x.service")" == 644 ]] || die "a wrong mode was not repaired"
[[ "$(reloads)" -eq 1 ]] || die "a repaired mode did not reload systemd"
log "ok: a unit file with the wrong mode is repaired"

if (ensure_system_unit_file "$work/missing.service") 2>/dev/null; then die "a missing source was accepted"; fi
log "ok: a missing source file is an error"

printf '[Unit]\nDescription=gone\n' > "$work/installed/vekrona-gone.service"
: > "$STUB_LOG"
STUB_ACTIVE=active ensure_system_unit_file_absent vekrona-gone.service 2>/dev/null
[[ ! -e "$work/installed/vekrona-gone.service" ]] || die "the unit file was not removed"
[[ "$(reloads)" -eq 1 ]] || die "removing a unit file did not reload systemd"
grep -qx 'systemctl stop vekrona-gone.service' "$STUB_LOG" || die "a unit that still runs was not stopped"
[[ "$(grep -n 'daemon-reload' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n 'systemctl stop' "$STUB_LOG" | cut -d: -f1)" ]] || die "the unit was stopped before systemd forgot its file"
log "ok: a removed unit file is forgotten, then the unit that still runs is stopped"

: > "$STUB_LOG"
ensure_system_unit_file_absent vekrona-gone.service 2>/dev/null
[[ "$(reloads)" -eq 0 ]] || die "an absent unit file reloaded systemd"
if grep -q 'systemctl stop' "$STUB_LOG"; then die "an inactive unit was stopped"; fi
if grep -q 'reset-failed' "$STUB_LOG"; then die "a unit that had not failed was reset"; fi
log "ok: an absent unit file and an inactive unit change nothing"

printf '[Unit]\nDescription=failed\n' > "$work/installed/vekrona-failed.service"
: > "$STUB_LOG"
STUB_FAILED=failed ensure_system_unit_file_absent vekrona-failed.service 2>/dev/null
grep -qx 'systemctl reset-failed vekrona-failed.service' "$STUB_LOG" || die "the failed state of a removed unit was kept"
[[ "$(grep -n 'daemon-reload' "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n 'reset-failed' "$STUB_LOG" | cut -d: -f1)" ]] || die "the failed state was cleared before systemd forgot the unit file"
log "ok: the failed state of a removed unit is cleared after systemd forgot its file"

: > "$STUB_LOG"
STUB_FAILED=failed ensure_system_unit_file_absent vekrona-failed.service 2>/dev/null
grep -qx 'systemctl reset-failed vekrona-failed.service' "$STUB_LOG" || die "the failed state of a unit whose file was already gone was kept"
log "ok: the failed state is cleared even when the file is already gone"

: > "$STUB_LOG"
STUB_NOT_FAILED_STATUS=4 ensure_system_unit_file_absent vekrona-failed.service 2>/dev/null
if grep -q 'reset-failed' "$STUB_LOG"; then die "a unit that systemd does not know (is-failed exits 4) was reset: $(cat "$STUB_LOG")"; fi
log "ok: a unit that systemd does not know is not failed"

# Neither state query may take a systemctl that fails for an answer: an inactive or unfailed unit would be left as it is.
for verb in is-active is-failed; do
  : > "$STUB_LOG"
  if (STUB_BREAK=$verb ensure_system_unit_file_absent vekrona-failed.service) 2>"$work/err"; then
    die "a systemctl $verb that fails was taken for an answer"
  fi
  grep -q "systemctl $verb vekrona-failed.service failed with status 5" "$work/err" || die "the failure of systemctl $verb is not reported: $(cat "$work/err")"
  if grep -q 'systemctl stop\|reset-failed' "$STUB_LOG"; then die "a unit was changed after systemctl $verb failed: $(cat "$STUB_LOG")"; fi
done
log "ok: a systemctl that fails when asked for the state of a removed unit is an error, and the unit is left alone"
