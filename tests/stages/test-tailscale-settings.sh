#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=../../lib/tailscale.sh
source "$ROOT/lib/tailscale.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
# A tailscaled of one preferences file; `set` writes it, unless FAKE_TS_KEEPS_NOTHING (a node that never logged in).
write_fake "$work/bin/tailscale" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_TS_LOG"
case "$1" in
  debug) cat "$FAKE_TS_PREFS" ;;
  set) [[ -n "${FAKE_TS_KEEPS_NOTHING:-}" ]] || echo '{"OperatorUser":"xiii","ShieldsUp":true,"RunSSH":false,"LoggedOut":false}' > "$FAKE_TS_PREFS" ;;
  *) exit 2 ;;
esac
F
export PATH="$work/bin:$PATH" FAKE_TS_PREFS="$work/prefs" FAKE_TS_LOG="$work/log"

echo '{"OperatorUser":"xiii","ShieldsUp":true,"RunSSH":false,"LoggedOut":false}' > "$FAKE_TS_PREFS"
: > "$FAKE_TS_LOG"
ensure_tailscale_settings xiii 2>/dev/null
[[ "$(<"$FAKE_TS_LOG")" == "debug prefs" ]] || die "settings that are already right must cost one read and no change: $(cat "$FAKE_TS_LOG")"
log "ok: settings that are already right are read once and left alone"

echo '{"OperatorUser":"","ShieldsUp":false,"RunSSH":true,"LoggedOut":true}' > "$FAKE_TS_PREFS"
: > "$FAKE_TS_LOG"
ensure_tailscale_settings xiii 2>/dev/null
grep -qx 'set --operator=xiii --shields-up=true --ssh=false' "$FAKE_TS_LOG" || die "wrong settings were not set: $(cat "$FAKE_TS_LOG")"
log "ok: wrong settings are set"

echo '{"OperatorUser":"","ShieldsUp":false,"RunSSH":true,"LoggedOut":true}' > "$FAKE_TS_PREFS"
if failure="$(FAKE_TS_KEEPS_NOTHING=1 ensure_tailscale_settings xiii 2>&1)"; then die "settings tailscaled did not keep were accepted"; fi
[[ "$failure" == *"tailscale up --shields-up --ssh=false"*"./install.sh 40"* ]] || die "the failure must say how to recover: $failure"
log "ok: settings that tailscaled does not keep fail with the way out"
