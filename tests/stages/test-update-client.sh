#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

# A journal that is a file: journalctl --follow prints its lines as they appear (an inotify wait, no polling), logger
# appends one, and the unit, as systemctl start --wait, appends its output and ends with the exit status in unit.rc.
cat > "$work/bin/journalctl" <<'F'
#!/usr/bin/env bash
echo "journalctl $*" >> "$STUB_LOG"
exec tail --follow=name --retry --lines=+1 "$JOURNAL"
F
cat > "$work/bin/logger" <<'F'
#!/usr/bin/env bash
printf '%s\n' "${*: -1}" >> "$JOURNAL"
F
cat > "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
printf '%s\n' "installing" "all done" >> "$JOURNAL"
exit "$(<"$UNIT_RC")"
F
chmod +x "$work/bin"/*
# A deadline for a client that never sees the end of the unit, not a pause.
CLIENT_DEADLINE_SEC=30
update_client() { timeout "$CLIENT_DEADLINE_SEC" "$REPO/bin/vekrona-update" "$@"; }
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" JOURNAL="$work/journal" UNIT_RC="$work/unit.rc"
: > "$JOURNAL"

echo 0 > "$UNIT_RC"
out="$(update_client 2>&1)"
[[ "$out" == $'installing\nall done' ]] || die "the unit's output was not shown whole and alone: '$out'"
grep -qx 'systemctl start --wait vekrona-update-now.service' "$STUB_LOG" || die "the unit was not started with --wait: $(cat "$STUB_LOG")"
grep -q -- '--since now' "$STUB_LOG" || die "the journal was not followed from now: $(cat "$STUB_LOG")"
log "ok: starts the unit, shows everything it printed and ends when it ends"

echo 3 > "$UNIT_RC"
status=0
update_client >/dev/null 2>&1 || status=$?
[[ "$status" -eq 3 ]] || die "exit status $status, expected the unit's 3"
log "ok: exits with the unit's result"

if [[ "$(id -u)" -ne 0 ]]; then
  status=0
  unshare -r "$REPO/bin/vekrona-update" >/dev/null 2>"$work/err" || status=$?
  [[ "$status" -ne 0 ]] && grep -q 'not root' "$work/err" || die "ran as root: $(cat "$work/err")"
  log "ok: refuses to run as root"
fi
