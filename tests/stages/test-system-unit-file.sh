#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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
