#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
tool="$ROOT/bin/vekrona-gtk-theme"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

export HOME="$scratch/home"
export XDG_STATE_HOME="$scratch/state"
theme_file="$XDG_STATE_HOME/vekrona/active-theme.json"
gtk3="$HOME/.config/gtk-3.0/gtk.css"
gtk4="$HOME/.config/gtk-4.0/gtk.css"
mkdir -p "$HOME" "$XDG_STATE_HOME/vekrona" "$scratch/stubs"

printf '#!/bin/sh\necho "$@" >> "%s/gsettings.log"\n' "$scratch" > "$scratch/stubs/gsettings"
chmod +x "$scratch/stubs/gsettings"
export PATH="$scratch/stubs:$PATH"

use_theme() { cp "$ROOT/config/dms-themes/tokyo-night.json" "$theme_file"; }
run_tool() { "$tool" >"$scratch/stdout" 2>"$scratch/stderr"; }

use_theme
run_tool || die "tool failed on a valid theme: $(cat "$scratch/stderr")"
for css in "$gtk3" "$gtk4"; do
  grep -qx '@define-color accent_bg_color #7aa2f7;' "$css" || die "$css: theme primary is not the accent"
  grep -qx '@define-color window_bg_color #1a1b26;' "$css" || die "$css: theme background is not the window color"
done
log "ok: both gtk.css files use the theme's colors"

grep -qx 'set org.gnome.desktop.interface gtk-theme adw-gtk3-dark' "$scratch/gsettings.log" || die "gtk-theme not set"
grep -qx 'set org.gnome.desktop.interface color-scheme prefer-dark' "$scratch/gsettings.log" || die "color-scheme not set"
log "ok: dark GTK theme and color scheme are selected"

before="$(cat "$gtk3")"
run_tool || die "re-running over its own files failed: $(cat "$scratch/stderr")"
[[ "$(cat "$gtk3")" == "$before" ]] || die "re-run changed the file"
log "ok: re-running is idempotent"

sed -i 's/#7aa2f7/#ff0000/' "$theme_file"
run_tool || die "tool failed after a theme change"
grep -qx '@define-color accent_bg_color #ff0000;' "$gtk4" || die "theme change did not reach gtk.css"
log "ok: a changed theme is picked up"

printf '/* mine */\n' > "$gtk4"
use_theme
if run_tool; then die "a foreign gtk.css must not be overwritten"; fi
[[ "$(cat "$gtk4")" == '/* mine */' ]] || die "foreign gtk.css was modified"
grep -q "not managed by vekrona" "$scratch/stderr" || die "foreign file refusal not explained: $(cat "$scratch/stderr")"
log "ok: a foreign gtk.css is refused and left alone"
rm "$gtk4"

rm "$theme_file"
if run_tool; then die "a missing theme file must fail"; fi
grep -q "not found" "$scratch/stderr" || die "missing theme not reported: $(cat "$scratch/stderr")"
log "ok: missing theme file fails"

echo 'not json' > "$theme_file"
if run_tool; then die "invalid JSON must fail"; fi
log "ok: invalid theme file fails"

jq 'del(.dark.primary)' "$ROOT/config/dms-themes/tokyo-night.json" > "$theme_file"
if run_tool; then die "a theme without primary must fail"; fi
grep -q "dark.primary" "$scratch/stderr" || die "missing key not named: $(cat "$scratch/stderr")"
log "ok: missing color key fails and is named"

jq '.dark.primary = "red"' "$ROOT/config/dms-themes/tokyo-night.json" > "$theme_file"
if run_tool; then die "a non-hex color must fail"; fi
log "ok: non-hex color fails"
