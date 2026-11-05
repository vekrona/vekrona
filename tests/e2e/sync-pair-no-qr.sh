#!/usr/bin/env bash
# "Pair another device…" without qrencode (a machine on which only stage 50 ran, so the desktop packages of stage 30 were not
# installed after qrencode was added to them): the popout says in plain words which program is missing and which stage installs
# it, in the place where the QR code would be, and everything else of the section works: the ID as text, Copy ID, and the field
# for the other device's ID (a wrong ID is still refused with Syncthing's reason). With qrencode back, closing and opening the
# section makes the code and the message goes; what was refused in the field is gone when the popout opens again. No other device
# is needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/sync-peer.sh
source "$ROOT/tests/e2e/lib/sync-peer.sh"
# shellcheck source=lib/bar-widget.sh
source "$ROOT/tests/e2e/lib/bar-widget.sh"
# shellcheck source=lib/sync-popout.sh
source "$ROOT/tests/e2e/lib/sync-popout.sh"

STEP_TIMEOUT_SEC=90
QRENCODE=/usr/bin/qrencode
HIDDEN="$QRENCODE.hidden-by-e2e"

hide_qrencode() { vekrona-dev run sudo mv "$QRENCODE" "$HIDDEN"; }
restore_qrencode() { vekrona-dev run bash -c '[[ ! -e "$2" ]] || sudo mv "$2" "$1"' _ "$QRENCODE" "$HIDDEN"; }
qr_png_exists() { vekrona-dev run bash -c 'test -s "$HOME/.local/state/vekrona/device-id.png"'; }
export -f qr_png_exists
cleanup() { run_cleanups restore_qrencode close_popout; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watcher_active
vekrona-dev run bash -c 'rm -f "$HOME/.local/state/vekrona/device-id.png"'
hide_qrencode

open_popout
click_word '^another$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'qrencode, which is\s+not installed'
text_shown 'install.sh 30' || die "the message must name the stage that installs qrencode"
text_shown 'This computer' || die "the ID of this computer must be shown without the QR code"
text_shown 'Copy ID' || die "Copy ID must be shown without the QR code"
text_shown "The other device's ID" || die "the field for the other device's ID must be shown without the QR code"
absent qr_png_exists || die "no QR code may have been made without qrencode"
snap pair-no-qr
log "ok: without qrencode the section says which program is missing and where to get it, and shows the ID, Copy ID and the field"

click_word '^Copy$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Copied'
log "ok: Copy ID still works"

click_word '^Paste$'
vekrona-dev type lizard
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'incorrect length'
log "ok: the field still refuses a word that is no device ID with Syncthing's reason"

restore_qrencode
click_word '^another$'
click_word '^another$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- qr_png_exists
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_absent 'qrencode, which is\s+not installed'
snap pair-qr-back
log "ok: with qrencode installed again the section makes the QR code and the message is gone"

close_popout
open_popout
click_word '^another$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Paste a device ID'
log "ok: a word that was refused is not still in the field when the popout is opened again"
