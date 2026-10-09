#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
FIRST_ENTRY=vekrona-clip-1
TRICKY_ENTRY=$'vekrona-tricky "double" \'single\' $HOME `tick`\nsecond line\\n'
OPEN_CHORD=super-ctrl-alt-v

nothing_matches() { vekrona-dev see text 'No matches'; }
copy() { vekrona-dev sh bash -c 'printf %s "$1" | base64 -d | wl-copy >/dev/null 2>&1' _ "$(printf %s "$1" | base64 -w0)"; }
stored() { vekrona-dev sh bash -c 'cliphist list | grep -qF "$1"' _ "$1"; }
pasted() { [[ "$(vekrona-dev sh bash -c 'wl-paste --no-newline | base64 -w0')" == "$(printf %s "$EXPECTED" | base64 -w0)" ]]; }
export -f nothing_matches stored pasted

export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
vekrona-dev sh systemctl --user is-active --quiet vekrona-cliphist.service || die "vekrona-cliphist.service must record the clipboard"

copy "$FIRST_ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- stored "$FIRST_ENTRY"
copy "$TRICKY_ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- stored vekrona-tricky
copy other

vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
log "ok: Hyper+v opens the clipboard history"

vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
log "ok: a query that matches no entry says so"
vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden

vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type clip-1
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
EXPECTED="$FIRST_ENTRY"
export EXPECTED
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pasted
log "ok: choosing an entry puts it back on the clipboard"

vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type tricky
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
EXPECTED="$TRICKY_ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pasted
log "ok: an entry with quotes, newlines and shell syntax comes back byte for byte"
