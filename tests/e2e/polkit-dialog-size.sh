#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PKEXEC_LOG=/tmp/vekrona-e2e-pkexec.log
MIN_WIDTH=460
MIN_HEIGHT=220
auth_window() { echo '[.. | objects | select(.app_id? == "com.danklinux.dms" and .name? == "Authentication")]'; }

auth_rect() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '$(auth_window) | first | \"\\(.rect.width) \\(.rect.height)\"'"; }
auth_open() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -e '$(auth_window) | length > 0' >/dev/null"; }
auth_closed() { ! auth_open; }
export -f auth_window auth_open auth_closed

vekrona-dev session
vekrona-dev spawn "$GUEST_PKEXEC_LOG" -- bash -c 'pkexec true; echo "pkexec exited $?"'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- auth_open

read -r width height <<<"$(auth_rect)"
((width >= MIN_WIDTH && height >= MIN_HEIGHT)) || die "the polkit Authentication dialog must open at least ${MIN_WIDTH}x${MIN_HEIGHT}, but it is ${width}x${height}"
log "ok: the polkit Authentication dialog opens at ${width}x${height}, large enough to use"

vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- auth_closed
log "ok: Escape dismisses the polkit Authentication dialog"
