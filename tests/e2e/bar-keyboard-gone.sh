#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
NEXT_LAYOUT_CHORD=super-ctrl-alt-space
vekrona-dev session
clear_notifications
vekrona-dev move 600 500

restore() { run_cleanups plug_keyboards 'set_layouts us'; }
trap restore EXIT
set_layouts us,ua

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown "EN"
read -r PILL_X y <<<"$(vekrona-dev see find "EN")"
[[ -n "${PILL_X:-}" && -n "${y:-}" ]] || die "the bar must show the layout code EN once the keymap has two layouts"
export PILL_X
log "ok: the bar shows EN for a us,ua keymap at x=$PILL_X"

errors_before="$(keyboard_errors)"
unplug_keyboards
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_keyboards
# The pill leaves EN only once the shell has read the empty list, so the input event is processed by then.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_hidden "EN"
[[ "$(keyboard_errors)" == "$errors_before" ]] || die "no keyboard at all is a normal state while the system resumes and must not log a Keyboard error"
log "ok: with every keyboard gone the shell logs no Keyboard error"

plug_keyboards
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "EN"
log "ok: the bar shows EN again once a keyboard is back"

vekrona-dev key "$NEXT_LAYOUT_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "UA"
log "ok: Hyper+Space switches to the next layout and the bar shows UA"
