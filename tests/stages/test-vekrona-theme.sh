#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# bin/vekrona-theme runs from a scratch tree whose renderer and `dms` are stubs. The stub DMS "confirms" a theme the way
# the real one does, by rewriting the GTK colors file, unless DMS_UNCONFIRMED is set; the real inotifywait watches it.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

tree="$scratch/tree"
mkdir -p "$tree/bin" "$tree/lib" "$scratch/stubs"
cp "$ROOT/bin/vekrona-theme" "$tree/bin/vekrona-theme"
cp "$ROOT/lib/common.sh" "$tree/lib/common.sh"

cat > "$tree/bin/vekrona-render-theme" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="$HOME/.local/state/vekrona"
mode="$(cat "$state/theme")"
printf '{"rendered":"%s","dark":{"surface":"#111111"},"light":{"surface":"#eeeeee"}}\n' "$mode" > "$state/active-theme.json"
STUB

cat > "$scratch/stubs/dms" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
state="$HOME/.local/state/vekrona"
echo "$*" >> "$HOME/dms-calls"
case "$*" in
  "ipc call theme getMode") ;;
  "ipc call theme "*) ;;
  "ipc call settings set currentThemeName custom")
    [[ -z "${DMS_UNCONFIRMED:-}" ]] || exit 0
    surface="$(jq -r --arg m "$(cat "$state/theme")" '.[$m].surface' "$state/active-theme.json")"
    printf '@define-color window_bg_color %s;\n' "$surface" > "$HOME/.config/gtk-4.0/.dank-colors.css.new"
    mv "$HOME/.config/gtk-4.0/.dank-colors.css.new" "$HOME/.config/gtk-4.0/dank-colors.css"
    ;;
  "ipc call settings set "*) ;;
  *) echo "dms stub: unexpected call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$tree/bin/vekrona-render-theme" "$scratch/stubs/dms"

export HOME="$scratch/home"
export PATH="$scratch/stubs:$PATH"
export VEKRONA_THEME_WAIT_SECONDS=1
unset XDG_STATE_HOME
state="$HOME/.local/state/vekrona"

theme() { ( "$tree/bin/vekrona-theme" "$@" ) >"$scratch/out" 2>&1; }
rendered() { jq -r .rendered "$state/active-theme.json"; }
last_dms_theme() { grep '^ipc call theme [dl]' "$HOME/dms-calls" | tail -n1; }

# Fresh home with the dark theme recorded, rendered and confirmed by DMS.
reset() {
  rm -rf "$HOME"
  mkdir -p "$state" "$HOME/.config/gtk-4.0"
  [[ "${1:-}" == none ]] || printf '%s\n' "${1:-dark}" > "$state/theme"
  [[ "${1:-}" == none ]] || printf '{"rendered":"%s"}\n' "${1:-dark}" > "$state/active-theme.json"
  printf '@define-color window_bg_color #111111;\n' > "$HOME/.config/gtk-4.0/dank-colors.css"
  : > "$HOME/dms-calls"
}

reset dark
theme light || die "dark to light failed: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == light && "$(rendered)" == light ]] || die "light not recorded and rendered"
[[ "$(last_dms_theme)" == "ipc call theme light" ]] || die "DMS not flipped to light"
log "ok: dark to light records, renders and flips DMS"

theme next || die "next from light failed: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark ]] || die "next did not toggle light to dark"
theme next || die "next from dark failed: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == light ]] || die "next did not toggle dark to light"
log "ok: next toggles"

reset dark
if DMS_UNCONFIRMED=1 theme light; then die "an unconfirmed theme must fail"; fi
grep -q "did not take in DMS" "$scratch/out" || die "failure not explained: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark ]] || die "mode not rolled back"
[[ "$(rendered)" == dark ]] || die "active theme not rolled back"
[[ "$(last_dms_theme)" == "ipc call theme dark" ]] || die "DMS not flipped back to dark"
log "ok: a theme DMS never confirms rolls back both files and the DMS mode"

reset none
if DMS_UNCONFIRMED=1 theme light; then die "an unconfirmed theme must fail without a recorded mode"; fi
[[ "$(cat "$state/theme")" == dark && "$(rendered)" == dark ]] || die "no recorded mode did not fall back to a rendered dark"
[[ "$(last_dms_theme)" == "ipc call theme dark" ]] || die "DMS not flipped to dark"
log "ok: a rollback with no recorded mode lands on a rendered dark"

reset dark
if theme sepia; then die "an unknown argument must fail"; fi
grep -q usage "$scratch/out" || die "unknown argument not explained: $(cat "$scratch/out")"
[[ "$(cat "$state/theme")" == dark && ! -s "$HOME/dms-calls" ]] || die "an unknown argument touched the theme"
log "ok: an unknown argument fails and touches nothing"
