#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
FIRST_ENTRY=vekrona-clip-1
TRICKY_ENTRY=$'vekrona-tricky "double" \'single\' $HOME `tick`\nsecond line\\n'
OPEN_CHORD=super-ctrl-alt-v

nothing_matches() { launcher_is '.query == "zzzzqqqq" and .rows == 0'; }
copy() { vekrona-dev sh bash -c 'printf %s "$1" | base64 -d | wl-copy >/dev/null 2>&1' _ "$(printf %s "$1" | base64 -w0)"; }
# 0 when the history holds the text $1, 1 when it does not, 70 when cliphist could not list it (a pipe would hide that).
stored() { vekrona-dev sh bash -c 'list="$(cliphist list)" || exit 70; grep -qF -- "$1" <<<"$list"' _ "$1"; }
pasted() { [[ "$(vekrona-dev sh bash -c 'wl-paste --no-newline | base64 -w0')" == "$(printf %s "$EXPECTED" | base64 -w0)" ]]; }
doomed_listed() { text_shown 'vekrona-doomed'; }
delete_armed() { launcher_is '.armed' && text_shown 'Press Enter again to delete'; }
history_open() { launcher_is '.open and .mode == "clip"'; }
doomed_gone() { absent stored vekrona-doomed; }
export -f nothing_matches stored pasted doomed_listed delete_armed history_open doomed_gone

trap close_launcher EXIT
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
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- history_open
log "ok: Hyper+v opens the clipboard history"

vekrona-dev type zzzzqqqq
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- nothing_matches
log "ok: a query that matches no entry lists no row"
vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
log "ok: Hyper+v again closes the clipboard history"

vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- history_open
vekrona-dev type clip-1
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
EXPECTED="$FIRST_ENTRY"
export EXPECTED
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pasted
log "ok: choosing an entry puts it back on the clipboard"

vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- history_open
vekrona-dev type tricky
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed
EXPECTED="$TRICKY_ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- pasted
log "ok: an entry with quotes, newlines and shell syntax comes back byte for byte"

copy vekrona-doomed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- stored vekrona-doomed
vekrona-dev key "$OPEN_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- history_open
vekrona-dev type doomed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- doomed_listed
vekrona-dev key ctrl-ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- delete_armed
stored vekrona-doomed || die "the first Ctrl+Enter on Delete must only arm it, but the entry is gone"
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- doomed_gone
launcher_is '.open and .mode == "clip" and (.armed | not)' || die "deleting an entry must keep the clipboard history open and disarmed"
log "ok: Delete needs a second Enter and then removes the entry"
