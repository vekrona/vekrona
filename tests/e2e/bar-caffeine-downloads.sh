#!/usr/bin/env bash
# The keep-awake menu's list of downloads reads file names of any shape, and says so when it cannot list at all instead of
# staying empty for good.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
# Inside the idle pill: its icon plus two paddings, and the edge is the icon's ink.
PILL_CLICK_OFFSET_PX=8
USER_DIRS='$HOME/.config/user-dirs.dirs'
USER_DIRS_STASH='$HOME/.config/user-dirs.dirs.e2e-stash'

# The keep-awake pill is the leftmost widget of the bar's right side; Hyper+Shift+c toggles a session and opens no menu.
click_pill() { vekrona-dev click "$(($(settled_bar_left_edge) + PILL_CLICK_OFFSET_PX))" "$((BAR_HEIGHT_PX / 2))"; }
popout_shown() { text_shown 'Stay awake for'; }
export -f popout_shown
# A click on the pill toggles the popout, so the one a scenario left open would be closed by the next scenario's click.
open_popout() { absent popout_shown && click_pill; vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- popout_shown; }
close_popout() { absent popout_shown || click_pill; }
remove_downloads() { vekrona-dev sh bash -c 'd=$(xdg-user-dir DOWNLOAD); rm -f "$d"/e2e-*.part'; }
restore_user_dirs() { vekrona-dev sh bash -c "if [[ -e $USER_DIRS_STASH ]]; then mv $USER_DIRS_STASH $USER_DIRS; fi"; }
trap 'run_cleanups close_popout remove_downloads restore_user_dirs' EXIT

vekrona-dev session
vekrona-dev move 600 500
clear_notifications

# A name with a newline and a tab in it: a listing that ends a record at a newline cannot tell where the file begins.
vekrona-dev sh bash -c 'd=$(xdg-user-dir DOWNLOAD); mkdir -p "$d"; printf x >"$d/$(printf "e2e-first\n\tsecond").part"'
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Wait for download'
vekrona-dev click-text '^download$'
# The pointer rests on the word it clicked and garbles it for the next OCR.
vekrona-dev move 600 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'second' || die "a download whose name holds a newline and a tab must be listed"
log "ok: a download with a newline and a tab in its name is listed"

vekrona-dev click-text '^download$'
vekrona-dev move 600 500
vekrona-dev sh bash -c "touch $USER_DIRS; cp -p $USER_DIRS $USER_DIRS_STASH; printf 'XDG_DOWNLOAD_DIR=\"/nonexistent-vekrona-downloads\"\n' >$USER_DIRS"
vekrona-dev click-text '^download$'
vekrona-dev move 600 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Could not read the list' || die "a list that cannot be read must say so"
log "ok: a download list that cannot be read says why instead of staying empty"
