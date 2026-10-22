#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-keybindings"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# vekrona-keybindings reads $HOME/.config/{sway,xremap}; point it at the repo's config.
mkdir -p "$scratch/home/.config"
ln -s "$ROOT/config/sway" "$scratch/home/.config/sway"
mkdir "$scratch/home/.config/xremap"
cp "$ROOT/config/xremap/config.yml" "$scratch/home/.config/xremap/config.yml"

run_check() { HOME="$scratch/home" "$tool" --check 2>"$scratch/stderr"; }

run_check || die "repo config fails --check: $(cat "$scratch/stderr")"
log "ok: repo config passes --check"

# Sway binds Mod4+q (kill), so remapping Super-q in xremap shadows it.
sed -i 's/^      Super-c: C-c$/&\n      Super-q: C-q/' "$scratch/home/.config/xremap/config.yml"
grep -qxF '      Super-q: C-q' "$scratch/home/.config/xremap/config.yml" || die "test setup: Super-q was not added to cmd-layer"
if run_check; then
  die "--check accepted a xremap Super-q remap that shadows the Sway Mod4+q binding"
fi
grep -q 'can never fire.*Mod4+q' "$scratch/stderr" || die "--check failed for the wrong reason: $(cat "$scratch/stderr")"
log "ok: --check rejects a xremap remap that shadows a Sway binding"

# The menu: the bin runs from a scratch tree whose theme renderer is a stub, with rofi and swaymsg stubs.
tree="$scratch/tree"
mkdir -p "$tree/bin" "$tree/lib" "$scratch/stubs"
cp "$tool" "$tree/bin/"
cp "$ROOT/lib/vekrona_cli.py" "$tree/lib/"
printf '#!/bin/sh\necho "* {}"\n' > "$tree/bin/vekrona-render-theme"
printf '#!/bin/sh\ncat >/dev/null\n[ -z "$ROFI_STDERR" ] || echo "$ROFI_STDERR" >&2\n[ -z "$ROFI_OUT" ] || echo "$ROFI_OUT"\nexit "${ROFI_STATUS:-0}"\n' > "$scratch/stubs/rofi"
printf '#!/bin/sh\necho "$*" >> "%s/swaymsg.log"\n' "$scratch" > "$scratch/stubs/swaymsg"
chmod +x "$tree/bin/vekrona-render-theme" "$scratch/stubs"/*
# Rewrite the menu's config back to the repo's: the shadowing remap above was only for --check.
cp "$ROOT/config/xremap/config.yml" "$scratch/home/.config/xremap/config.yml"
export ROFI_STDERR="" ROFI_OUT="" ROFI_STATUS=0

run_menu() {
  rm -f "$scratch/swaymsg.log"
  rc=0
  HOME="$scratch/home" PATH="$scratch/stubs:$PATH" "$tree/bin/vekrona-keybindings" menu >/dev/null 2>"$scratch/stderr" || rc=$?
}

ROFI_STATUS=1 run_menu
[[ "$rc" == 0 && ! -e "$scratch/swaymsg.log" ]] || die "Esc in the menu must end quietly: exit $rc, $(cat "$scratch/stderr")"
log "ok: Esc in the menu ends quietly"

ROFI_STATUS=65 ROFI_STDERR="theme parse error" run_menu
[[ "$rc" == 1 ]] || die "a rofi that failed must fail the command, got exit $rc"
grep -q 'rofi exited with status 65: theme parse error' "$scratch/stderr" || die "the rofi failure is not reported: $(cat "$scratch/stderr")"
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
