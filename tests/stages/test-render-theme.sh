#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The tool finds config/tokens.json and config/design.json relative to itself, so it runs from a scratch
# copy of the tree whose inputs a test may break.
repo="$scratch/repo"
mkdir -p "$repo/bin" "$repo/lib" "$repo/config"
cp "$ROOT/bin/vekrona-render-theme" "$repo/bin/"
cp "$ROOT/lib/vekrona_cli.py" "$ROOT/lib/vekrona_theme.py" "$repo/lib/"
cp "$ROOT/config/tokens.json" "$ROOT/config/design.json" "$repo/config/"
tool="$repo/bin/vekrona-render-theme"

export HOME="$scratch/home"
export XDG_STATE_HOME="$scratch/state"
unset XDG_CONFIG_HOME SWAYSOCK
mode_file="$XDG_STATE_HOME/vekrona/theme"
active_json="$XDG_STATE_HOME/vekrona/active-theme.json"
gtk3="$HOME/.config/gtk-3.0/gtk.css"
gtk4="$HOME/.config/gtk-4.0/gtk.css"
qt_conf="$HOME/.config/qt6ct/qt6ct.conf"
qt_colors="$HOME/.config/qt6ct/colors/vekrona.conf"
sway_conf="$HOME/.config/sway/config.d/90-vekrona-design.conf"
ff_root="$HOME/.config/mozilla/firefox"
ff_profile="$ff_root/abc.default-release"
ff_webapp="$ff_root/vekrona-youtube"
mkdir -p "$HOME" "$XDG_STATE_HOME/vekrona" "$scratch/stubs"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$scratch/stubs/$1"; chmod +x "$scratch/stubs/$1"; }
stub gsettings 'echo "$@" >> "'"$scratch"'/gsettings.log"'
stub swaymsg 'echo "$@" >> "'"$scratch"'/swaymsg.log"; exit "$(cat "'"$scratch"'/swaymsg.status" 2>/dev/null || echo 0)"'
stub notify-send 'exit 0'
stub vekrona-error 'exit 0'
export PATH="$scratch/stubs:$PATH"

tok() { jq -er --arg m "$1" --arg n "$2" '.color.tokens[] | select(.name == $n) | .value[$m]' "$ROOT/config/tokens.json"; }
set_mode() { printf '%s\n' "$1" > "$mode_file"; }
run_tool() { "$tool" "$@" >"$scratch/stdout" 2>"$scratch/stderr"; }
ok_run() { run_tool "$@" || die "$*: $(cat "$scratch/stderr")"; }
fails() { # fails <why> <stderr-substring> <tool args...>
  local why="$1" needle="$2"; shift 2
  if run_tool "$@"; then die "$why: must fail"; fi
  grep -qF -- "$needle" "$scratch/stderr" || die "$why: error does not say '$needle': $(cat "$scratch/stderr")"
}
expect_line() { grep -qxF -- "$2" "$1" || die "$1: missing line: $2"; }
expect_text() { grep -qF -- "$2" "$1" || die "$1: missing text: $2"; }
refute_text() { ! grep -qF -- "$2" "$1" || die "$1: must not contain: $2"; }
swaymsg_calls() { [[ -f "$scratch/swaymsg.log" ]] && wc -l < "$scratch/swaymsg.log" || echo 0; }
snapshot() { find "$HOME" "$XDG_STATE_HOME" -type f -print0 | sort -z | xargs -0 md5sum; }
write_profiles_ini() {
  mkdir -p "$ff_profile" "$ff_webapp"
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
reset_home() { rm -rf "$HOME" "$scratch/gsettings.log" "$scratch/swaymsg.log"; mkdir -p "$HOME"; write_profiles_ini; }

check_mode() { # check_mode <dark|light>: every target renders that mode's tokens
  local m="$1" bg s1 s2 s3 ink muted dis line strong accent on_accent accent_ink focus danger on_danger danger_ink
  bg=$(tok "$m" bg); s1=$(tok "$m" surface-1); s2=$(tok "$m" surface-2); s3=$(tok "$m" surface-3)
  ink=$(tok "$m" ink); muted=$(tok "$m" ink-muted); dis=$(tok "$m" ink-disabled)
  line=$(tok "$m" line); strong=$(tok "$m" line-strong); accent=$(tok "$m" accent); on_accent=$(tok "$m" on-accent)
  accent_ink=$(tok "$m" accent-ink); focus=$(tok "$m" focus)
  danger=$(tok "$m" danger); on_danger=$(tok "$m" on-danger); danger_ink=$(tok "$m" danger-ink)
  reset_home
  set_mode "$m"
  ok_run all

  # dms: both modes in one file, the current one named
  [[ "$(jq -r .mode "$active_json")" == "$m" ]] || die "$m: active-theme.json mode is not $m"
  for each in dark light; do
    [[ "$(jq -r ".$each.primary" "$active_json")" == "$(tok "$each" accent)" ]] || die "$m: $each.primary is not accent"
    [[ "$(jq -r ".$each.surfaceContainerHigh" "$active_json")" == "$(tok "$each" surface-2)" ]] || die "$m: $each.surfaceContainerHigh is not surface-2"
    [[ "$(jq -r ".$each.outline" "$active_json")" == "$(tok "$each" line-strong)" ]] || die "$m: $each.outline is not line-strong"
    [[ "$(jq -r ".$each.error" "$active_json")" == "$(tok "$each" danger)" ]] || die "$m: $each.error is not danger"
    [[ "$(jq -r ".$each.tokens.dangerInk" "$active_json")" == "$(tok "$each" danger-ink)" ]] || die "$m: $each.tokens.dangerInk is not danger-ink"
    [[ "$(jq -r ".$each.tokens.surface1" "$active_json")" == "$(tok "$each" surface-1)" ]] || die "$m: $each.tokens.surface1 is not surface-1"
  done
  [[ "$(jq -c '.metrics.spacing.space2, .metrics.border.indicator, .metrics.border.focusOffset, .metrics.size.bar, .metrics.opacity.scrim' "$active_json" | tr '\n' ' ')" == "8 2 2 36 0.6 " ]] \
    || die "$m: metrics do not follow tokens.json"
  [[ "$(jq -r '.metrics.font.sans | join(",")' "$active_json")" == "Atkinson Hyperlegible Next,Atkinson Hyperlegible,Inter" ]] || die "$m: sans list keeps generics or is reordered"
  [[ "$(jq -c '.metrics.type.label' "$active_json")" == '{"size":13,"line":18,"weight":600,"tracking":0.02}' ]] || die "$m: label type style wrong"

  for css in "$gtk3" "$gtk4"; do
    expect_line "$css" "@define-color window_bg_color $s1;"
    expect_line "$css" "@define-color view_bg_color $s2;"
    expect_line "$css" "@define-color card_bg_color $s2;"
    expect_line "$css" "@define-color headerbar_bg_color $s1;"
    expect_line "$css" "@define-color window_fg_color $ink;"
    expect_line "$css" "@define-color accent_bg_color $accent;"
    expect_line "$css" "@define-color accent_fg_color $on_accent;"
    expect_line "$css" "@define-color accent_color $accent_ink;"
    expect_line "$css" "@define-color destructive_bg_color $danger;"
    expect_line "$css" "@define-color destructive_fg_color $on_danger;"
    expect_line "$css" "@define-color destructive_color $danger_ink;"
    expect_line "$css" "@define-color error_bg_color $danger;"
    expect_line "$css" "@define-color warning_bg_color $(tok "$m" warning);"
    expect_line "$css" "@define-color success_fg_color $(tok "$m" on-success);"
    expect_line "$css" "@define-color vk_focus $focus;"
    expect_line "$css" "@define-color vk_line $line;"
    expect_line "$css" "@define-color vk_line_strong $strong;"
    expect_text "$css" "border-radius: 0px;"
    expect_text "$css" "box-shadow: none;"
    expect_text "$css" "background-image: none;"
    expect_text "$css" "outline: 1px solid @vk_focus;"
    expect_text "$css" "outline-offset: 2px;"
    expect_text "$css" "border-bottom: 2px solid transparent;"
    expect_text "$css" "border-bottom-color: @accent_bg_color;"
    expect_text "$css" "border-bottom: 1px solid @vk_line;"
  done
  local scheme=prefer-$m theme=adw-gtk3-dark
  [[ "$m" == light ]] && theme=adw-gtk3
  expect_line "$scratch/gsettings.log" "set org.gnome.desktop.interface gtk-theme $theme"
  expect_line "$scratch/gsettings.log" "set org.gnome.desktop.interface color-scheme $scheme"
  expect_line "$scratch/gsettings.log" "set org.gnome.desktop.interface font-name Atkinson Hyperlegible Next 11.25"
  expect_line "$scratch/gsettings.log" "set org.gnome.desktop.interface document-font-name Atkinson Hyperlegible Next 11.25"
  expect_line "$scratch/gsettings.log" "set org.gnome.desktop.interface monospace-font-name AtkynsonMono Nerd Font 10.5"

  expect_line "$qt_conf" 'style=Fusion'
  expect_line "$qt_conf" "color_scheme_path=$qt_colors"
  expect_line "$qt_conf" 'general="Atkinson Hyperlegible Next,11.25"'
  expect_line "$qt_conf" 'fixed="AtkynsonMono Nerd Font,10.5"'
  local kind line_ roles
  for kind in active inactive disabled; do
    line_="$(grep "^${kind}_colors=" "$qt_colors")" || die "$m: no ${kind}_colors line"
    roles="$(tr ',' '\n' <<<"${line_#*=}" | wc -l)"
    [[ "$roles" -eq 21 ]] || die "$m: ${kind}_colors has $roles roles, not 21"
  done
  # roles: WindowText Button Light Midlight Dark Mid Text BrightText ButtonText Base Window Shadow Highlight HighlightedText Link LinkVisited AlternateBase NoRole ToolTipBase ToolTipText PlaceholderText
  expect_line "$qt_colors" "active_colors=$ink, $s2, $s3, $s2, $line, $strong, $ink, $ink, $ink, $s2, $s1, $bg, $accent, $on_accent, $accent_ink, $muted, $s1, $s1, $s2, $ink, $muted"
  expect_line "$qt_colors" "disabled_colors=$dis, $s2, $s3, $s2, $line, $strong, $dis, $dis, $dis, $s2, $s1, $bg, $s3, $dis, $accent_ink, $muted, $s1, $s1, $s2, $dis, $dis"

  expect_line "$sway_conf" 'font pango:Atkinson Hyperlegible Next 11.25'
  expect_line "$sway_conf" 'default_border pixel 1'
  expect_line "$sway_conf" 'gaps inner 8'
  expect_line "$sway_conf" "output * bg $bg solid_color"
  expect_line "$sway_conf" "client.focused $accent $accent $on_accent $accent $accent"
  expect_line "$sway_conf" "client.focused_inactive $line $s1 $muted $line $line"
  expect_line "$sway_conf" "client.unfocused $line $s1 $muted $line $line"
  expect_line "$sway_conf" "client.urgent $danger $danger $on_danger $danger $danger"

  local want_theme=0
  [[ "$m" == light ]] && want_theme=1
  expect_text "$ff_profile/user.js" "toolkit.legacyUserProfileCustomizations.stylesheets\", true"
  expect_text "$ff_profile/user.js" "browser.theme.toolbar-theme\", $want_theme"
  local chrome
  for chrome in "$ff_profile/chrome/userChrome.css" "$ff_webapp/chrome/userChrome.css"; do
    expect_text "$chrome" "--toolbar-bgcolor: $s1 !important;"
    expect_text "$chrome" "--toolbar-field-background-color: $s2 !important;"
    expect_text "$chrome" "--focus-outline-color: $focus !important;"
    expect_text "$chrome" "border-bottom: 2px solid $accent !important;"
    expect_text "$chrome" "outline: 1px solid $focus !important;"
    expect_text "$chrome" "outline-offset: 2px !important;"
    expect_text "$chrome" "border-radius: 0px !important;"
    expect_text "$chrome" "box-shadow: none !important;"
  done
  refute_text "$ff_profile/chrome/userChrome.css" "visibility: collapse"
  expect_text "$ff_webapp/chrome/userChrome.css" "visibility: collapse !important;"
  [[ ! -e "$ff_webapp/user.js" ]] || die "$m: the webapp user.js belongs to stage 50, not the renderer"

  ok_run rofi
  expect_line "$scratch/stdout" "    font: \"AtkynsonMono Nerd Font 10.5\";"
  expect_line "$scratch/stdout" "    background: $bg;"
  expect_line "$scratch/stdout" "    border-color: $strong;"
  expect_line "$scratch/stdout" "    urgent-foreground: $danger_ink;"
  expect_line "$scratch/stdout" "    active-foreground: $accent_ink;"
  expect_line "$scratch/stdout" "    selected-normal-background: transparent;"
  expect_text "$scratch/stdout" "border: 0 0 2px;"
  expect_text "$scratch/stdout" "border-color: $accent;"
  expect_text "$scratch/stdout" "border-radius: 0px;"
}

check_mode dark
log "ok: dark mode renders dms, gtk, gsettings, qt, sway, firefox and rofi from the tokens"
check_mode light
log "ok: light mode renders every target from the light tokens"

# ---- idempotence
before="$(snapshot)"
ok_run all
[[ "$(snapshot)" == "$before" ]] || die "re-run changed files"
! grep -q '^wrote:' "$scratch/stdout" || die "re-run reports writes: $(cat "$scratch/stdout")"
log "ok: re-running is idempotent"

# ---- sway reload only on change
reset_home; set_mode dark; ok_run all
export SWAYSOCK=/nonexistent
set_mode light
ok_run sway
[[ "$(swaymsg_calls)" -eq 1 ]] && grep -qx 'reload' "$scratch/swaymsg.log" || die "changed config did not trigger exactly one swaymsg reload"
ok_run sway
[[ "$(swaymsg_calls)" -eq 1 ]] || die "unchanged config triggered a reload"
set_mode dark
echo 1 > "$scratch/swaymsg.status"
fails "a failing swaymsg reload" "swaymsg reload failed" sway
rm "$scratch/swaymsg.status"
unset SWAYSOCK
log "ok: sway reloads only when its config changed, and a failing reload fails the tool"

# ---- switching modes rewrites the files
set_mode dark; ok_run all
dark_gtk="$(cat "$gtk4")"
set_mode light; ok_run all
[[ "$(cat "$gtk4")" != "$dark_gtk" ]] || die "switching to light left gtk.css unchanged"
log "ok: a mode switch is picked up"

# ---- targets
reset_home; set_mode dark
ok_run dms
[[ -f "$active_json" && ! -e "$gtk4" && ! -e "$sway_conf" ]] || die "dms target must write only active-theme.json"
status=0
run_tool lizard || status=$?
[[ "$status" -eq 2 ]] || die "an unknown target must exit 2, got $status"
grep -q 'usage:' "$scratch/stderr" || die "unknown target did not print usage"
log "ok: dms is a target of its own; an unknown target prints usage and exits 2"

# ---- rofi writes nothing
rm -rf "$HOME" "$XDG_STATE_HOME/vekrona/active-theme.json"; mkdir -p "$HOME"
before="$(find "$HOME" "$XDG_STATE_HOME" | sort)"
ok_run rofi
[[ "$(find "$HOME" "$XDG_STATE_HOME" | sort)" == "$before" ]] || die "rofi wrote files"
log "ok: rofi prints and writes nothing"

# ---- foreign and legacy files
reset_home; set_mode dark
mkdir -p "$(dirname "$gtk4")"
printf '/* mine */\n' > "$gtk4"
mkdir -p "$(dirname "$gtk3")"
fails "a foreign gtk.css" "not managed by vekrona" gtk
[[ "$(cat "$gtk4")" == '/* mine */' ]] || die "foreign gtk.css was modified"
[[ ! -e "$gtk3" ]] || die "gtk-3.0/gtk.css was written although gtk-4.0/gtk.css is foreign (not two-phase)"
printf '/* vekrona-gtk-theme: generated from the active vekrona theme, do not edit (run vekrona-theme or vekrona-gtk-theme) */\n' > "$gtk4"
fails "a legacy-marker gtk.css" "not managed by vekrona" gtk
log "ok: a foreign gtk.css is refused, left alone, and nothing else is written"

reset_home
mkdir -p "$(dirname "$qt_conf")"; printf '# mine\n' > "$qt_conf"
fails "a foreign qt6ct.conf" "not managed by vekrona" qt
[[ "$(cat "$qt_conf")" == '# mine' ]] || die "foreign qt6ct.conf was modified"
log "ok: a foreign qt6ct.conf is refused"

reset_home
printf '// mine\n' > "$ff_profile/user.js"
fails "a foreign user.js" "not managed by vekrona" firefox
[[ ! -e "$ff_profile/chrome/userChrome.css" && ! -e "$ff_webapp/chrome/userChrome.css" ]] \
  || die "userChrome.css written although user.js is foreign (not two-phase)"
log "ok: a foreign user.js is refused before anything is written"

# ---- firefox profiles
reset_home
mkdir -p "$ff_webapp/chrome" "$repo/config/firefox"
echo '#nav-bar { old: 1 }' > "$repo/config/firefox/userChrome.css"
ln -s "$repo/config/firefox/userChrome.css" "$ff_webapp/chrome/userChrome.css"
ok_run firefox
[[ ! -L "$ff_webapp/chrome/userChrome.css" ]] || die "the repo symlink was not replaced"
expect_text "$ff_webapp/chrome/userChrome.css" "visibility: collapse"
[[ "$(cat "$repo/config/firefox/userChrome.css")" == '#nav-bar { old: 1 }' ]] || die "the symlink target in the repo was modified"
rm "$ff_webapp/chrome/userChrome.css"
echo '/* dotfiles */' > "$scratch/dotfiles.css"
ln -s "$scratch/dotfiles.css" "$ff_webapp/chrome/userChrome.css"
fails "a symlink to a foreign file" "not managed by vekrona" firefox
[[ "$(cat "$scratch/dotfiles.css")" == '/* dotfiles */' ]] || die "foreign symlink target was modified"
log "ok: a symlink into the repo is replaced, one to a foreign file is refused"

rm -rf "$ff_root"
fails "firefox without profiles.ini" "no default Firefox profile" firefox
ok_run all
grep -q 'no default Firefox profile yet' "$scratch/stderr" || die "skipped firefox without a notice"
log "ok: no Firefox profile fails 'firefox' and is skipped with a notice under 'all'"

mkdir -p "$ff_root"
printf '[Install1]\nDefault=a\n\n[Install2]\nDefault=b\n' > "$ff_root/profiles.ini"
fails "two Install sections" "Install1" firefox
log "ok: ambiguous default profile is refused"

# ---- invalid inputs
reset_home; set_mode dark
break_tokens() { jq "$1" "$ROOT/config/tokens.json" > "$repo/config/tokens.json"; }
break_tokens '(.color.tokens[] | select(.name == "accent") | .value.dark) = "teal"'
fails "a non-hex color" "token accent" gtk
break_tokens '(.color.tokens[] | select(.name == "focus") | .value) |= del(.light)'
fails "a missing mode value" "token focus: light" gtk
break_tokens '.color.tokens |= map(select(.name != "on-info"))'
fails "a missing token" "token on-info" gtk
break_tokens '(.size.tokens[] | select(.name == "size-bar") | .value) = "tall"'
fails "a unit that does not parse" "token size-bar" gtk
break_tokens '(.type.groups[0].styles[] | select(.name == "body") | .fontSize) = "15"'
fails "a font size without unit" "token body" gtk
[[ ! -e "$gtk4" ]] || die "gtk.css written from invalid tokens"
cp "$ROOT/config/tokens.json" "$repo/config/tokens.json"

for legacy in tokyo-night Dark ""; do
  printf '%s\n' "$legacy" > "$mode_file"
  fails "theme value '$legacy'" "vekrona-theme dark" gtk
done
rm "$mode_file"
fails "no theme file" "vekrona-theme dark" gtk
set_mode dark

for bad in '"0"' '-1' '0.5' 'true' 'null'; do
  jq ".radius = $bad" "$ROOT/config/design.json" > "$repo/config/design.json"
  fails "design radius $bad" "radius" gtk
done
jq '.dmsFontScale = 0' "$ROOT/config/design.json" > "$repo/config/design.json"
fails "design dmsFontScale 0" "dmsFontScale" gtk
jq 'del(.barInnerPadding)' "$ROOT/config/design.json" > "$repo/config/design.json"
fails "a design.json missing a key" "keys must be exactly" gtk
jq '. + {gap: 8}' "$ROOT/config/design.json" > "$repo/config/design.json"
fails "a design.json with a retired key" "keys must be exactly" gtk
cp "$ROOT/config/design.json" "$repo/config/design.json"
log "ok: bad tokens, theme state and design.json fail early and name the culprit"

# ---- contrast guard on the shipped tokens
python3 - "$ROOT/config/tokens.json" <<'PY' || die "contrast guard failed (see above)"
import json, sys

tokens = {t["name"]: t["value"] for t in json.load(open(sys.argv[1]))["color"]["tokens"]}

def lum(hex_):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(int(hex_[i:i + 2], 16)) for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b

def ratio(a, b):
    la, lb = sorted((lum(a), lum(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)

grounds = ("bg", "surface-1", "surface-2", "surface-3")
pairs = [(fg, g, 7) for fg in ("ink", "ink-muted") for g in grounds]
pairs += [(f"on-{x}", x, 7) for x in ("accent", "danger", "warning", "success", "info")]
pairs += [(fg, "bg", 3) for fg in ("line-strong", "focus", "accent")]
failures = []
for mode in ("dark", "light"):
    for fg, bg, floor in pairs:
        got = ratio(tokens[fg][mode], tokens[bg][mode])
        if got < floor:
            failures.append(f"{mode}: {fg} on {bg} is {got:.2f}:1, needs {floor}:1")
if failures:
    sys.exit("\n".join(failures))
PY
log "ok: text pairs reach 7:1 and line-strong, focus and accent reach 3:1 in both modes"

# ---- fontconfig drift guard
# EXPECTED TO FAIL until the fontconfig chunk merges: it adds Atkinson Hyperlegible to the sans list.
# Failing is reported as XFAIL; once the lists match this prints ok, and the XFAIL branch must then be deleted.
if python3 - "$ROOT/config/tokens.json" "$ROOT/config/fontconfig/conf.d/50-vekrona-fonts.conf" <<'PY'
import json, sys
import xml.etree.ElementTree as ET

generic = {"system-ui", "sans-serif", "ui-monospace", "monospace"}
families = json.load(open(sys.argv[1]))["type"]["families"]
want = {k: [f.strip().strip('"') for f in families[k].split(",") if f.strip().strip('"') not in generic]
        for k in ("sans", "mono")}
have = {}
for alias in ET.parse(sys.argv[2]).getroot().iter("alias"):
    name = alias.findtext("family")
    have[name] = [f.text for f in alias.find("prefer").iter("family")]
bad = []
for alias, key in (("sans-serif", "sans"), ("system-ui", "sans"), ("monospace", "mono")):
    if have.get(alias) != want[key]:
        bad.append(f"fontconfig {alias}: {have.get(alias)} != tokens {key}: {want[key]}")
if bad:
    sys.exit("\n".join(bad))
PY
then
  log "ok: fontconfig family lists equal the token families"
else
  log "XFAIL (until the fontconfig chunk merges): fontconfig family lists differ from the token families"
fi
