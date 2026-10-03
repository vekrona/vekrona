#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The tool finds config/design.json relative to itself, so it runs from a scratch copy of the tree
# whose design.json a test may break.
repo="$scratch/repo"
mkdir -p "$repo/bin" "$repo/lib" "$repo/config"
cp "$ROOT/bin/vekrona-render-theme" "$repo/bin/"
cp "$ROOT/lib/vekrona_cli.py" "$repo/lib/"
cp "$ROOT/config/design.json" "$repo/config/"
tool="$repo/bin/vekrona-render-theme"

export HOME="$scratch/home"
export XDG_STATE_HOME="$scratch/state"
unset XDG_CONFIG_HOME SWAYSOCK
theme_file="$XDG_STATE_HOME/vekrona/active-theme.json"
gtk3="$HOME/.config/gtk-3.0/gtk.css"
gtk4="$HOME/.config/gtk-4.0/gtk.css"
qt_conf="$HOME/.config/qt6ct/qt6ct.conf"
qt_colors="$HOME/.config/qt6ct/colors/vekrona.conf"
sway_conf="$HOME/.config/sway/config.d/90-vekrona-design.conf"
ff_root="$HOME/.config/mozilla/firefox"
ff_profile="$ff_root/abc.default-release"
mkdir -p "$HOME" "$XDG_STATE_HOME/vekrona" "$scratch/stubs"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$scratch/stubs/$1"; chmod +x "$scratch/stubs/$1"; }
stub gsettings 'echo "$@" >> "'"$scratch"'/gsettings.log"'
stub swaymsg 'echo "$@" >> "'"$scratch"'/swaymsg.log"; exit "$(cat "'"$scratch"'/swaymsg.status" 2>/dev/null || echo 0)"'
stub notify-send 'exit 0'
stub vekrona-error 'exit 0'
export PATH="$scratch/stubs:$PATH"

use_theme() { cp "$ROOT/config/dms-themes/tokyo-night.json" "$theme_file"; }
run_tool() { "$tool" "$@" >"$scratch/stdout" 2>"$scratch/stderr"; }
fails() { # fails <why> <stderr-substring> <tool args...>
  local why="$1" needle="$2"; shift 2
  if run_tool "$@"; then die "$why: must fail"; fi
  grep -qF -- "$needle" "$scratch/stderr" || die "$why: error does not say '$needle': $(cat "$scratch/stderr")"
}
swaymsg_calls() { [[ -f "$scratch/swaymsg.log" ]] && wc -l < "$scratch/swaymsg.log" || echo 0; }
write_profiles_ini() {
  mkdir -p "$ff_profile" "$ff_root/vekrona-youtube"
  cat > "$ff_root/profiles.ini" <<INI
[Profile1]
Name=vekrona-youtube
IsRelative=1
Path=vekrona-youtube

[Profile0]
Name=default-release
IsRelative=1
Path=abc.default-release
Default=1

[Install4F96D1932A9F858E]
Default=abc.default-release
Locked=1
INI
}

use_theme

# ---- gtk
jq '.dark.surfaceContainer = "#123456"' "$ROOT/config/dms-themes/tokyo-night.json" > "$theme_file"
run_tool gtk || die "gtk failed: $(cat "$scratch/stderr")"
grep -qx '@define-color headerbar_bg_color #1a1b26;' "$gtk4" || die "headerbar is not flat on the window color"
grep -qx '@define-color sidebar_bg_color #123456;' "$gtk4" || die "sidebar is not the surfaceContainer color"
use_theme
run_tool gtk || die "gtk failed on a valid theme: $(cat "$scratch/stderr")"
for css in "$gtk3" "$gtk4"; do
  grep -qx '@define-color accent_bg_color #7aa2f7;' "$css" || die "$css: theme primary is not the accent"
  grep -qx '@define-color window_bg_color #1a1b26;' "$css" || die "$css: theme background is not the window color"
  grep -q 'border-radius: 6px;' "$css" || die "$css: no design radius"
  grep -q 'border-bottom: none;' "$css" || die "$css: headerbar keeps its bottom border"
done
log "ok: gtk.css files use the theme's colors and the design radius, headerbars are borderless"

grep -qx 'set org.gnome.desktop.interface gtk-theme adw-gtk3-dark' "$scratch/gsettings.log" || die "gtk-theme not set"
grep -qx 'set org.gnome.desktop.interface color-scheme prefer-dark' "$scratch/gsettings.log" || die "color-scheme not set"
log "ok: dark GTK theme and color scheme are selected"

before="$(cat "$gtk3")"
run_tool gtk || die "re-running over its own files failed: $(cat "$scratch/stderr")"
[[ "$(cat "$gtk3")" == "$before" ]] || die "re-run changed the file"
log "ok: re-running is idempotent"

sed -i 's/#7aa2f7/#ff0000/' "$theme_file"
run_tool gtk || die "gtk failed after a theme change"
grep -qx '@define-color accent_bg_color #ff0000;' "$gtk4" || die "theme change did not reach gtk.css"
log "ok: a changed theme is picked up"
use_theme

printf '/* mine */\n' > "$gtk4"
rm "$gtk3"
fails "a foreign gtk.css" "not managed by vekrona" gtk
[[ "$(cat "$gtk4")" == '/* mine */' ]] || die "foreign gtk.css was modified"
[[ ! -e "$gtk3" ]] || die "gtk-3.0/gtk.css was written although gtk-4.0/gtk.css is foreign (not two-phase)"
log "ok: a foreign gtk.css is refused, left alone, and nothing else is written"

printf '/* vekrona-gtk-theme: generated from the active vekrona theme, do not edit (run vekrona-theme or vekrona-gtk-theme) */\n' > "$gtk4"
run_tool gtk || die "a file with the legacy marker must be overwritten: $(cat "$scratch/stderr")"
head -n 1 "$gtk4" | grep -q '^/\* vekrona-render-theme: ' || die "legacy file not migrated to the new marker"
log "ok: a gtk.css with the legacy marker is migrated"

# ---- qt
run_tool qt || die "qt failed: $(cat "$scratch/stderr")"
grep -qx 'style=Fusion' "$qt_conf" || die "qt6ct style is not Fusion"
grep -qx "color_scheme_path=$qt_colors" "$qt_conf" || die "color_scheme_path is not the absolute scheme path"
for kind in active inactive disabled; do
  line="$(grep "^${kind}_colors=" "$qt_colors")" || die "no ${kind}_colors line"
  [[ "$(tr ',' '\n' <<<"${line#*=}" | wc -l)" -eq 21 ]] || die "${kind}_colors does not have 21 roles: $line"
done
grep -q '^active_colors=#c0caf5,' "$qt_colors" || die "first active color is not the theme's backgroundText"
grep -q '^disabled_colors=#656a83,' "$qt_colors" || die "disabled text is not the dimmed mix of backgroundText and background"
log "ok: qt6ct config and palette (21 roles each)"

printf '# mine\n' > "$qt_conf"
fails "a foreign qt6ct.conf" "not managed by vekrona" qt
[[ "$(cat "$qt_conf")" == '# mine' ]] || die "foreign qt6ct.conf was modified"
log "ok: a foreign qt6ct.conf is refused"
rm "$qt_conf"

# ---- firefox
fails "firefox without profiles.ini" "no default Firefox profile" firefox
run_tool all || die "all must succeed when Firefox has no profile yet: $(cat "$scratch/stderr")"
grep -q 'no default Firefox profile yet' "$scratch/stderr" || die "skipped firefox without a notice"
log "ok: no Firefox profile fails 'firefox' and is skipped with a notice under 'all'"

write_profiles_ini
run_tool firefox || die "firefox failed: $(cat "$scratch/stderr")"
grep -q 'toolkit.legacyUserProfileCustomizations.stylesheets", true' "$ff_profile/user.js" || die "user.js does not enable stylesheets"
grep -q -- '--tab-selected-bgcolor: #2e3047 !important;' "$ff_profile/chrome/userChrome.css" || die "selected tab is not surfaceContainerHigh"
[[ -z "$(ls -A "$ff_root/vekrona-youtube")" ]] || die "webapp profile was touched"
log "ok: only the default Firefox profile gets user.js and userChrome.css"

printf '// mine\n' > "$ff_profile/user.js"
rm "$ff_profile/chrome/userChrome.css"
fails "a foreign user.js" "not managed by vekrona" firefox
[[ ! -e "$ff_profile/chrome/userChrome.css" ]] || die "userChrome.css written although user.js is foreign (not two-phase)"
log "ok: a foreign user.js is refused before anything is written"
rm "$ff_profile/user.js"

printf '[Install1]\nDefault=a\n\n[Install2]\nDefault=b\n' > "$ff_root/profiles.ini"
fails "two Install sections" "Install1" firefox
log "ok: ambiguous default profile is refused"
write_profiles_ini

# ---- sway
rm -f "$scratch/swaymsg.log"
run_tool sway || die "sway failed: $(cat "$scratch/stderr")"
grep -qx 'gaps inner 8' "$sway_conf" || die "gaps are not the design gap"
grep -qx 'client.focused #7aa2f7 #7aa2f7 #1a1b26 #7aa2f7 #7aa2f7' "$sway_conf" || die "focused border is not primary"
[[ "$(swaymsg_calls)" -eq 0 ]] || die "swaymsg called without SWAYSOCK"
log "ok: sway drop-in written, no reload outside sway"

export SWAYSOCK=/nonexistent
sed -i 's/#7aa2f7/#ff0000/' "$theme_file"
run_tool sway || die "sway failed with SWAYSOCK: $(cat "$scratch/stderr")"
[[ "$(swaymsg_calls)" -eq 1 ]] && grep -qx 'reload' "$scratch/swaymsg.log" || die "changed config did not trigger exactly one swaymsg reload"
run_tool sway || die "sway failed on unchanged config"
[[ "$(swaymsg_calls)" -eq 1 ]] || die "unchanged config triggered a reload"
log "ok: reload only when the sway config changed"

use_theme
echo 1 > "$scratch/swaymsg.status"
fails "a failing swaymsg reload" "swaymsg reload failed" sway
rm "$scratch/swaymsg.status"
unset SWAYSOCK
log "ok: a failing reload fails the tool"

# ---- rofi
rm -rf "$HOME/.config"
before="$(find "$HOME" | sort)"
run_tool rofi || die "rofi failed: $(cat "$scratch/stderr")"
grep -qx '    selected-normal-background: #7aa2f7;' "$scratch/stdout" || die "rofi selection is not primary"
grep -q 'border-radius: 6px;' "$scratch/stdout" || die "rofi has no design radius"
[[ "$(find "$HOME" | sort)" == "$before" ]] || die "rofi wrote files under HOME"
log "ok: rofi prints the theme and writes nothing"

# ---- common failures
rm "$theme_file"
fails "a missing theme file" "not found"
echo 'not json' > "$theme_file"
fails "invalid JSON" "could not read"
jq 'del(.dark.primary)' "$ROOT/config/dms-themes/tokyo-night.json" > "$theme_file"
fails "a theme without primary" "dark.primary"
jq '.dark.primary = "red"' "$ROOT/config/dms-themes/tokyo-night.json" > "$theme_file"
fails "a non-hex color" "dark.primary"
use_theme
for bad in '"6"' '-1' '6.5' 'true' 'null'; do
  jq ".radius = $bad" "$ROOT/config/design.json" > "$repo/config/design.json"
  fails "design radius $bad" "radius"
done
echo '{ "radius": 6, "padding": 12 }' > "$repo/config/design.json"
fails "design.json without gap" "gap"
cp "$ROOT/config/design.json" "$repo/config/design.json"
log "ok: missing/invalid theme and design values fail and are named"

status=0
run_tool lizard || status=$?
[[ "$status" -eq 2 ]] || die "an unknown target must exit 2, got $status"
grep -q 'usage:' "$scratch/stderr" || die "unknown target did not print usage"
log "ok: unknown target prints usage and exits 2"
