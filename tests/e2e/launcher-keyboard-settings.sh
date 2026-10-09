#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60

keyboard_layouts_shown() { vekrona-dev see text 'Keyboard layouts'; }
layouts_info_shown() { vekrona-dev see text 'Layouts come from your system keymap'; }
export -f keyboard_layouts_shown layouts_info_shown
export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

vekrona-dev session
vekrona-dev move 600 500
clear_notifications

# The scenario opens the launcher by IPC; leaving it open would hand the next scenario a screen it did not expect.
# Escape steps back one level per press (subview, then settings mode, then the launcher), so press until it is gone.
escape_then_hidden() { vekrona-dev key esc; panel_hidden; }
export -f escape_then_hidden
close_launcher() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- escape_then_hidden; }
trap close_launcher EXIT

# Test IPC call to open keyboard settings subview directly
vekrona-dev sh qs -c vekrona-shell ipc call launcher settings keyboard
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- keyboard_layouts_shown
log "ok: ipc call launcher settings keyboard opens the keyboard layouts subview"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- layouts_info_shown
log "ok: keyboard layouts subview shows layout information"
