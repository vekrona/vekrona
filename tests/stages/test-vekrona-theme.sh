#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# bin/vekrona-theme runs from a scratch tree whose renderer is a stub. The stub renders the recorded mode into
# active-theme.json, and fails when RENDER_FAILS is set and the recorded mode is the one it names.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

tree="$scratch/tree"
mkdir -p "$tree/bin" "$tree/lib"
cp "$ROOT/bin/vekrona-theme" "$tree/bin/vekrona-theme"
cp "$ROOT/lib/common.sh" "$tree/lib/common.sh"

cat > "$tree/bin/vekrona-render-theme" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="$HOME/.local/state/vekrona"
mode="$(cat "$state/theme")"
[[ "${RENDER_FAILS:-}" != "$mode" ]] || { echo "render stub: refusing $mode" >&2; exit 1; }
printf '{"rendered":"%s"}\n' "$mode" > "$state/active-theme.json"
STUB
chmod +x "$tree/bin/vekrona-render-theme"

export HOME="$scratch/home"
unset XDG_STATE_HOME
state="$HOME/.local/state/vekrona"

theme() { ( "$tree/bin/vekrona-theme" "$@" ) >"$scratch/out" 2>&1; }
rendered() { jq -r .rendered "$state/active-theme.json"; }

# Fresh home with the given theme recorded and rendered; "none" records nothing.
reset() {
  rm -rf "$HOME"
  mkdir -p "$state"
  [[ "${1:-}" == none ]] || printf '%s\n' "${1:-dark}" > "$state/theme"
  [[ "${1:-}" == none ]] || printf '{"rendered":"%s"}\n' "${1:-dark}" > "$state/active-theme.json"
}

reset dark
theme light || die "dark to light failed: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == light && "$(rendered)" == light ]] || die "light not recorded and rendered"
log "ok: dark to light records and renders"

theme next || die "next from light failed: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark ]] || die "next did not toggle light to dark"
theme next || die "next from dark failed: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == light ]] || die "next did not toggle dark to light"
log "ok: next toggles"

reset dark
if RENDER_FAILS=light theme light; then die "a failing render must fail"; fi
grep -q "refusing light" "$scratch/out" || die "failure not explained: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark ]] || die "mode not rolled back"
[[ "$(rendered)" == dark ]] || die "active theme not rolled back"
log "ok: a render that fails rolls back both files"

reset none
if RENDER_FAILS=light theme light; then die "a failing render must fail without a recorded mode"; fi
[[ "$(cat "$state/theme")" == dark && "$(rendered)" == dark ]] || die "no recorded mode did not fall back to a rendered dark"
log "ok: a rollback with no recorded mode lands on a rendered dark"

reset dark
if theme sepia; then die "an unknown argument must fail"; fi
grep -q usage "$scratch/out" || die "unknown argument not explained: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark ]] || die "an unknown argument touched the theme"
log "ok: an unknown argument fails and touches nothing"
