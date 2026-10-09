#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90

obsidian_window() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -ce '[.. | objects | select(.pid? and ((.app_id // .window_properties.class // \"\") | test(\"obsidian\"; \"i\")))] | first // error(\"no Obsidian window\")'"; }
stop_obsidian() { vekrona-dev run bash -c 'if flatpak ps --columns=application | grep -qx md.obsidian.Obsidian; then flatpak kill md.obsidian.Obsidian; fi'; }
export -f obsidian_window

# Obsidian is single-instance: a copy left running would answer the launch with its old window.
stop_obsidian
trap stop_obsidian EXIT

# Without a registered vault Obsidian opens its fixed-size vault picker, not the main window.
vekrona-dev run bash -c 'set -euo pipefail
  vault="$HOME/Documents/e2e-vault"
  config="$HOME/.var/app/md.obsidian.Obsidian/config/obsidian"
  mkdir -p "$vault" "$config"
  printf "{\"vaults\":{\"e2e\":{\"path\":\"%s\",\"ts\":0,\"open\":true}}}\n" "$vault" >"$config/obsidian.json"'

vekrona-dev session
vekrona-dev sh swaymsg exec "flatpak run md.obsidian.Obsidian" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- obsidian_window >/dev/null
window="$(obsidian_window)"
log "ok: Obsidian opens its vault window"

shell="$(jq -r .shell <<<"$window")"
[[ "$shell" == xdg_shell ]] || die "Obsidian runs under $shell, so sway blurs it at a fractional output scale: $window"
log "ok: Obsidian is a native Wayland window"

[[ "$(jq -r .type <<<"$window")" == con ]] || die "Obsidian opened floating: $window"
log "ok: Obsidian tiles"
