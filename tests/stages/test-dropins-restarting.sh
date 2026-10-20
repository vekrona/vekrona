#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/src" "$work/dst"

write_fake "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
write_fake "$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
FAKE
export PATH="$work/bin:$PATH" STUB_LOG="$work/log"
: > "$STUB_LOG"

ensure() { (ensure_dropins_restarting unit.service "$work/src" "$work/dst" "$@") 2>"$work/err" || die "ensure_dropins_restarting $* failed: $(<"$work/err")"; }
restarts() { grep -c '^systemctl try-restart unit.service$' "$STUB_LOG" || true; }

echo one > "$work/src/a.conf"
echo two > "$work/src/b.conf"

ensure a.conf b.conf
[[ "$(restarts)" == 1 ]] || die "new drop-ins did not restart the unit once: $(<"$STUB_LOG")"
log "ok: new drop-ins restart the unit"

ensure a.conf b.conf
[[ "$(restarts)" == 1 ]] || die "unchanged drop-ins restarted the unit: $(<"$STUB_LOG")"
log "ok: unchanged drop-ins leave the unit alone"

echo changed > "$work/src/b.conf"
ensure a.conf b.conf
[[ "$(restarts)" == 2 && "$(<"$work/dst/b.conf")" == changed ]] || die "a changed drop-in did not restart the unit once more: $(<"$STUB_LOG")"
log "ok: one changed drop-in of several restarts the unit"

if (ensure_dropins_restarting unit.service "$work/src" "$work/dst" missing.conf) 2>"$work/err"; then die "a missing source was accepted"; fi
[[ "$(restarts)" == 2 ]] || die "a failed install restarted the unit: $(<"$STUB_LOG")"
log "ok: a drop-in that cannot be installed is an error and restarts nothing"
