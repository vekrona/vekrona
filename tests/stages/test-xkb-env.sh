#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
tool="$ROOT/bin/vekrona-xkb-env"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

write_conf() {
  local layout="$1" variant="$2" options="$3"
  {
    echo 'Section "InputClass"'
    echo '        Identifier "system-keyboard"'
    echo '        MatchIsKeyboard "on"'
    echo "        Option \"XkbLayout\" \"$layout\""
    [[ -z "$variant" ]] || echo "        Option \"XkbVariant\" \"$variant\""
    [[ -z "$options" ]] || echo "        Option \"XkbOptions\" \"$options\""
    echo 'EndSection'
  } > "$scratch/00-keyboard.conf"
}

run_tool() { VEKRONA_XKB_CONF="$scratch/00-keyboard.conf" "$tool" 2>"$scratch/stderr"; }

expect_output() {
  local description="$1" expected="$2" got
  got="$(run_tool)" || die "$description: tool failed: $(cat "$scratch/stderr")"
  [[ "$got" == "$expected" ]] || die "$description: expected
$expected
got
$got"
  log "ok: $description"
}

write_conf us "" ""
expect_output "single layout gets no group switch" "XKB_DEFAULT_LAYOUT='us'
XKB_DEFAULT_VARIANT=''
XKB_DEFAULT_MODEL=''
XKB_DEFAULT_OPTIONS='shift:both_capslock_cancel'"

write_conf "us,ua" "" "grp:alt_shift_toggle,caps:escape"
expect_output "several layouts get Alt+Alt instead of the installer's switch combo" "XKB_DEFAULT_LAYOUT='us,ua'
XKB_DEFAULT_VARIANT=''
XKB_DEFAULT_MODEL=''
XKB_DEFAULT_OPTIONS='caps:escape,grp:alts_toggle,shift:both_capslock_cancel'"

write_conf "de" "nodeadkeys" "grp:alt_shift_toggle"
expect_output "variant is kept and a stray group switch is dropped for one layout" "XKB_DEFAULT_LAYOUT='de'
XKB_DEFAULT_VARIANT='nodeadkeys'
XKB_DEFAULT_MODEL=''
XKB_DEFAULT_OPTIONS='shift:both_capslock_cancel'"

rm "$scratch/00-keyboard.conf"
expect_output "a missing X11 keymap gets us explicitly" "XKB_DEFAULT_LAYOUT='us'
XKB_DEFAULT_VARIANT=''
XKB_DEFAULT_MODEL=''
XKB_DEFAULT_OPTIONS='shift:both_capslock_cancel'"
grep -q "no X11 keymap configured" "$scratch/stderr" || die "missing keymap must be reported on stderr"
log "ok: missing keymap is reported"

write_conf "" "" ""
if run_tool >/dev/null; then die "an empty XkbLayout must be rejected"; fi
grep -q "XkbLayout is empty" "$scratch/stderr" || die "empty XkbLayout error not reported: $(cat "$scratch/stderr")"
log "ok: empty XkbLayout rejected"

write_conf 'us;rm' "" ""
if run_tool >/dev/null; then die "unsafe characters must be rejected"; fi
log "ok: unsafe characters rejected"

write_conf "us(dvorak)" "" ""
expect_output "parentheses in a layout are shell-quoted" "XKB_DEFAULT_LAYOUT='us(dvorak)'
XKB_DEFAULT_VARIANT=''
XKB_DEFAULT_MODEL=''
XKB_DEFAULT_OPTIONS='shift:both_capslock_cancel'"

write_conf "us,ua" "" "grp_led:scroll,shift:both_capslock_cancel"
expect_output "grp_led option is kept and shift:both_capslock_cancel is not duplicated" "XKB_DEFAULT_LAYOUT='us,ua'
XKB_DEFAULT_VARIANT=''
XKB_DEFAULT_MODEL=''
XKB_DEFAULT_OPTIONS='grp_led:scroll,shift:both_capslock_cancel,grp:alts_toggle'"

stubs="$scratch/stubs"
mkdir -p "$stubs"
printf '#!/bin/sh\ncat >> "%s/logged"\n' "$scratch" > "$stubs/logger"
printf '#!/bin/sh\necho none\n' > "$stubs/systemd-detect-virt"
printf '#!/bin/sh\n' > "$stubs/vekrona-gpu-env"
chmod +x "$stubs/logger" "$stubs/systemd-detect-virt" "$stubs/vekrona-gpu-env"
# The session file may reach only these host tools (resolved now, so hosts without /usr/bin and /bin work too).
for tool_name in sh bash env cat mktemp rm grep sed tail; do
  ln -s "$(command -v "$tool_name")" "$stubs/$tool_name"
done

session_environment() {
  # shellcheck disable=SC2016 # $1 expands in the inner sh
  env -i PATH="$stubs" HOME="$scratch/home" VEKRONA_XKB_CONF="$scratch/00-keyboard.conf" \
    sh -c 'set -o allexport; . "$1/config/sway/environment"; set +o allexport; env' sh "$ROOT"
}

write_conf "us(dvorak)" "" ""
ln -sf "$tool" "$stubs/vekrona-xkb-env"
env_dump="$(session_environment)" || die "sourcing config/sway/environment failed"
grep -qx 'XKB_DEFAULT_LAYOUT=us(dvorak)' <<<"$env_dump" || die "layout with parentheses did not reach the environment"
if grep -qE '^(xkb_|vekrona_)' <<<"$env_dump"; then die "helper variables leaked into the exported environment"; fi
[[ ! -e "$scratch/logged" ]] || die "a healthy keymap must not log an error: $(cat "$scratch/logged")"
log "ok: sway environment exports the keymap without leaking helpers"

write_conf "" "" ""
env_dump="$(session_environment)" || die "a broken keymap must not stop the session environment"
grep -qx 'XKB_DEFAULT_LAYOUT=us' <<<"$env_dump" || die "broken keymap must fall back to us"
grep -qx 'XKB_DEFAULT_OPTIONS=shift:both_capslock_cancel' <<<"$env_dump" || die "fallback options missing"
grep -q "XkbLayout is empty" "$scratch/logged" || die "the broken keymap was not logged"
log "ok: broken keymap falls back to us and is logged"

rm -f "$scratch/logged" "$stubs/vekrona-xkb-env"
env_dump="$(session_environment)" || die "a missing tool must not stop the session environment"
grep -qx 'XKB_DEFAULT_LAYOUT=us' <<<"$env_dump" || die "missing tool must fall back to us"
grep -q "missing or failed" "$scratch/logged" || die "the missing tool was not logged"
log "ok: missing tool falls back to us and is logged"

rm -f "$scratch/logged"
printf '#!/bin/sh\necho "export WLR_DRM_DEVICES=/dev/dri/card1"\n' > "$stubs/vekrona-gpu-env"
write_conf "us" "" ""
ln -sf "$tool" "$stubs/vekrona-xkb-env"
env_dump="$(session_environment)" || die "sourcing config/sway/environment failed"
grep -qx 'WLR_DRM_DEVICES=/dev/dri/card1' <<<"$env_dump" || die "the GPU choice did not reach the environment"
[[ ! -e "$scratch/logged" ]] || die "a healthy GPU tool must not log: $(cat "$scratch/logged")"
log "ok: GPU choice from vekrona-gpu-env reaches the environment"

rm -f "$stubs/vekrona-gpu-env"
env_dump="$(session_environment)" || die "a missing GPU tool must not stop the session environment"
grep -qx 'XKB_DEFAULT_LAYOUT=us' <<<"$env_dump" || die "the session environment did not complete after a missing GPU tool"
if grep -q '^WLR_DRM_DEVICES=' <<<"$env_dump"; then die "a missing GPU tool must not set WLR_DRM_DEVICES"; fi
grep -q "missing or failed" "$scratch/logged" || die "the missing GPU tool was not logged"
log "ok: missing GPU tool leaves the choice to wlroots and is logged"
