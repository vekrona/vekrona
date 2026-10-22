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
[[ "$*" == all ]] || { echo "render stub: expected the target all, got: $*" >&2; exit 2; }
state="$HOME/.local/state/vekrona"
mode="$(cat "$state/theme")"
[[ "${RENDER_FAILS:-}" != "$mode" && "${RENDER_FAILS:-}" != any ]] || { echo "render stub: refusing $mode" >&2; exit 1; }
printf '{"rendered":"%s"}\n' "$mode" > "$state/active-theme.json"
STUB
chmod +x "$tree/bin/vekrona-render-theme"

printf '#!/bin/sh\necho "$*" >> "%s/reported"\n' "$scratch" > "$scratch/reporter"
chmod +x "$scratch/reporter"
export VEKRONA_ERROR_REPORTER="$scratch/reporter"

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

# vekrona-theme runs from a key binding, with no terminal to read: its own failures are reported, once each, so the
# robot shows them. A usage error is not one: nothing failed, so nothing is recorded and no dot lights.
reset dark
rm -f "$scratch/reported"
if theme sepia; then die "an unknown argument must fail"; fi
grep -q usage "$scratch/out" || die "unknown argument not explained: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark ]] || die "an unknown argument touched the theme"
[[ ! -e "$scratch/reported" ]] || die "a usage error must record nothing: $(cat "$scratch/reported")"
log "ok: an unknown argument fails, touches nothing and records nothing"

reset dark
rm -f "$scratch/reported"
if RENDER_FAILS=any theme light; then die "a render that fails twice must fail"; fi
[[ "$(wc -l < "$scratch/reported")" == 1 ]] || die "a failed rollback must be reported once: $(cat "$scratch/reported" 2>&1)"
grep -q "re-rendering 'dark' after the failure failed" "$scratch/reported" || die "the report must name the rollback: $(cat "$scratch/reported")"
log "ok: a rollback whose re-render fails is reported"

# A second change while one runs would interleave with it. The lock is held here, so the tool waits for it: with no wait
# allowed it must give up, and touch nothing.
reset dark
rm -f "$scratch/reported"
exec {held}>"$state/theme.lock"
flock "$held"
for command in next light; do
  if VEKRONA_THEME_LOCK_WAIT_SEC=0 theme "$command"; then die "'$command' ran while another change held the lock"; fi
  grep -q "another vekrona-theme is still running" "$scratch/out" || die "'$command' did not say why it gave up: $(cat "$scratch/out")"
done
[[ "$(cat "$state/theme")" == dark && "$(rendered)" == dark ]] || die "a change that gave up touched the theme"
exec {held}>&-
theme next || die "next failed once the lock was free: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == light && "$(rendered)" == light ]] || die "next did not toggle once the lock was free"
log "ok: a change waits for the one running, gives up with a message, and touches nothing meanwhile"
