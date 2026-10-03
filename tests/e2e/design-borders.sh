#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"

STEP_TIMEOUT_SEC=30
GUEST_TERMINAL_LOG=/tmp/vekrona-e2e-terminal.log
DROP_IN='~/.config/sway/config.d/90-vekrona-design.conf'

focused_terminal() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq '[.. | objects | select(.focused? == true and .app_id? == \"com.mitchellh.ghostty\")][0].current_border_width // empty'"; }
terminal_is_focused() { [[ -n "$(focused_terminal)" ]]; }
export -f focused_terminal terminal_is_focused

vekrona-dev session
vekrona-dev run bash -c "test -s $DROP_IN" || die "the design drop-in $DROP_IN is missing: vekrona-render-theme sway did not run"

vekrona-dev spawn "$GUEST_TERMINAL_LOG" -- ghostty
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- terminal_is_focused
width="$(focused_terminal)"
[[ "$width" == 1 ]] || die "a focused terminal must have a 1 px border from the design drop-in, but it has $width px"
log "ok: the design drop-in gives focused windows a 1 px border"
