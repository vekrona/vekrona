#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# vekrona-keybindings reads the Sway config from $HOME/.config/sway and the xremap config from the checkout it runs from
# (found through its own real path). The home has no ~/.config/xremap. The bin runs from a scratch tree with the real
# vekrona-rofi-menu, a stub theme renderer, and rofi, swaymsg and error reporter stubs.
mkdir -p "$scratch/home/.config"
ln -s "$ROOT/config/sway" "$scratch/home/.config/sway"
tree="$scratch/tree"
mkdir -p "$tree/bin" "$tree/config/xremap" "$scratch/stubs"
cp -r "$ROOT/lib" "$tree/"
cp "$ROOT/bin/vekrona-keybindings" "$ROOT/bin/vekrona-rofi-menu" "$tree/bin/"
cp "$ROOT/config/xremap/config.yml" "$tree/config/xremap/config.yml"
tool="$tree/bin/vekrona-keybindings"
xremap_config="$tree/config/xremap/config.yml"

run_check() { HOME="$scratch/home" "$tool" --check 2>"$scratch/stderr"; }

run_check || die "repo config fails --check: $(cat "$scratch/stderr")"
log "ok: repo config passes --check"

# The app switcher's sway mode repeats Cmd+Tab; the cheat sheet must still list it once.
list="$(HOME="$scratch/home" "$tool" --list)"
# grep -c prints 0 and exits 1 when nothing matches; only a higher status is a failure.
tab_rows="$(grep -c '^Cmd + Tab ' <<<"$list" || (($? == 1)))"
[[ "$tab_rows" == 1 ]] || die "--list must list 'Cmd + Tab' exactly once, but lists it $tab_rows times"
log "ok: --list shows Cmd + Tab once"

# Sway binds Mod4+q (kill), so remapping Super-q in xremap shadows it.
sed -i 's/^      Super-c: C-c$/&\n      Super-q: C-q/' "$xremap_config"
grep -qxF '      Super-q: C-q' "$xremap_config" || die "test setup: Super-q was not added to cmd-layer"
if run_check; then
  die "--check accepted a xremap Super-q remap that shadows the Sway Mod4+q binding"
fi
grep -q 'can never fire.*Mod4+q' "$scratch/stderr" || die "--check failed for the wrong reason: $(cat "$scratch/stderr")"
log "ok: --check rejects a xremap remap that shadows a Sway binding"

# The menu.
printf '#!/bin/sh\necho "* {}"\n' > "$tree/bin/vekrona-render-theme"
printf '#!/bin/sh\ncat >/dev/null\n[ -z "$ROFI_STDERR" ] || echo "$ROFI_STDERR" >&2\n[ -z "$ROFI_OUT" ] || echo "$ROFI_OUT"\nexit "${ROFI_STATUS:-0}"\n' > "$scratch/stubs/rofi"
printf '#!/bin/sh\necho "$*" >> "%s/swaymsg.log"\n' "$scratch" > "$scratch/stubs/swaymsg"
printf '#!/bin/sh\necho "$*" >> "%s/reported"\n' "$scratch" > "$scratch/stubs/reporter"
chmod +x "$tree/bin/vekrona-render-theme" "$scratch/stubs"/*
export VEKRONA_ERROR_REPORTER="$scratch/stubs/reporter"
# Rewrite the menu's config back to the repo's: the shadowing remap above was only for --check.
cp "$ROOT/config/xremap/config.yml" "$xremap_config"
export ROFI_STDERR="" ROFI_OUT="" ROFI_STATUS=0

run_menu() {
  rm -f "$scratch/swaymsg.log" "$scratch/reported"
  rc=0
  HOME="$scratch/home" PATH="$scratch/stubs:$PATH" "$tool" menu >/dev/null 2>"$scratch/stderr" || rc=$?
}

ROFI_STATUS=1 run_menu
[[ "$rc" == 0 && ! -e "$scratch/swaymsg.log" ]] || die "Esc in the menu must end quietly: exit $rc, $(cat "$scratch/stderr")"
log "ok: Esc in the menu ends quietly"

ROFI_STATUS=65 ROFI_STDERR="theme parse error" run_menu
[[ "$rc" == 1 ]] || die "a rofi that failed must fail the command, got exit $rc"
grep -q 'rofi exited with status 65: theme parse error' "$scratch/stderr" || die "the rofi failure is not reported: $(cat "$scratch/stderr")"
[[ "$(grep -c 'rofi exited with status 65: theme parse error' "$scratch/reported")" == 1 ]] || die "the rofi failure must be recorded exactly once: $(cat "$scratch/reported" 2>&1)"
log "ok: a rofi failure is not taken for Esc"

for answer in -1 99999 lizard; do
  ROFI_OUT="$answer" run_menu
  [[ "$rc" == 1 && ! -e "$scratch/swaymsg.log" ]] || die "an answer '$answer' outside the menu must fail without running a row: exit $rc, $(cat "$scratch/stderr")"
  grep -q 'not a row of the menu' "$scratch/stderr" || die "answer '$answer' is not reported: $(cat "$scratch/stderr")"
done
log "ok: an answer that is no row runs nothing and fails"

ROFI_OUT=0 run_menu
[[ "$rc" == 0 && -s "$scratch/swaymsg.log" ]] || die "choosing the first row must run its command: exit $rc, $(cat "$scratch/stderr")"
log "ok: a chosen row runs its command through swaymsg"
