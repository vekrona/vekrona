#!/usr/bin/env bash
# The bar's VPN popout walks the tree vendor > country > configuration with real input only (pointer clicks on the words it shows,
# key presses), against a stand-in for vekrona-vpn that records its calls (tests/e2e/lib/vpn-popout.sh):
#   - a country with one configuration connects at once, a Mullvad country connects by its code, a country with two shows them;
#   - Esc steps back out of a vendor and, at the top, closes the popout;
#   - Off turns the VPN off;
#   - Forget is reached with Tab and Enter, asks first, does nothing on Cancel, and removes the configuration from the list on Forget;
#   - Mullvad without an account shows the account field with the keyboard in it, refuses a wrong number in words, and passes the right
#     one on the tool's stdin, never in its arguments;
#   - a tunnel that is up without the kill switch (brought up outside vekrona-vpn) is called "Not protected" and the popout says why;
#   - Import closes the popout before it calls the tool, and a failure of the tool comes as a notification;
#   - a connect, a forget, a login and an import close the popout, since their keyring prompt needs the keyboard, and a failed connect
#     comes as a notification.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/bar-widget.sh
source "$ROOT/tests/e2e/lib/bar-widget.sh"
# shellcheck source=lib/vpn-popout.sh
source "$ROOT/tests/e2e/lib/vpn-popout.sh"

STEP_TIMEOUT_SEC=90
ZURICH=11111111-1111-1111-1111-111111111111
TOKYO=22222222-2222-2222-2222-222222222222
OSAKA=33333333-3333-3333-3333-333333333333
# While a connection is up the popout names it above the vendors ("Proton VPN, JP, Osaka"), so the row of the vendor is the last word
# "Proton" of the screen.
# Words as OCR reads them in the bold face: the double l of Mullvad for an l and a t, the ff of Off for an f and a t.
MULLVAD='^Mul[lt]vad$'
OFF='^[Oo]f[ft]$'
# The number that the stand-in accepts (tests/e2e/vpn-stub.py).
ACCOUNT=1111222233334444

# The last row of the popout, which is always there.
popout_open() { text_shown 'Import'; }
export -f popout_open
open_popout() {
  if absent popout_open; then click_vpn_pill; fi
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- popout_open
}
close_popout() { absent popout_open || click_vpn_pill; }
# Opens the popout afresh, which puts it at the vendors with the keyboard parked, as a person finds it.
reopen_popout() {
  close_popout
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open
  open_popout
}
await_word() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- word_shown "$1"; }
await_gone() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent word_shown "$1"; }
await_called() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vpn_called "$1"; }
never_called() { absent vpn_called "$1" || die "the tool must not have been called with: $1"; }
stub_file() { vekrona-dev run bash -c 'cat "$HOME/.cache/vekrona-vpn-stub/$1"' _ "$1"; }
cleanup() { run_cleanups close_popout vpn_stub_remove; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vpn_stub_install
vpn_stub_set list "$VPN_LIST"
vpn_stub_set status "$VPN_STATUS_OFF"
vpn_announce
vekrona-dev move "$POINTER_REST_X" "$POINTER_REST_Y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_widget center vpn >/dev/null || die "the bar must show the VPN icon"

open_popout
await_word "$MULLVAD"
await_word '^Proton$'
await_word '^Other$'
await_word "$OFF"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Not\s+logged\s+in'
snap vendors
log "ok: the popout lists the vendors, says the VPN is off and that Mullvad has no account"

click_word --last '^Proton$'
await_word '^Switzerland$'
await_word '^Japan$'
click_word '^Switzerland$'
await_called "connect $ZURICH"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open || die "a connect must close the popout, for the keyring prompt"
open_popout
await_word '^Connected$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Zurich'
snap connected
log "ok: a country with one configuration connects at once; the popout closes for the keyring, and reopened it says which is up"

click_word --last '^Proton$'
await_word '^Switzerland$'
vekrona-dev key esc
await_word "$MULLVAD"
await_gone '^Switzerland$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- popout_open
log "ok: Esc steps back out of a vendor"

click_word --last '^Proton$'
click_word '^Japan$'
await_word '^Tokyo$'
await_word '^Osaka$'
snap configurations
click_word '^Osaka$'
await_called "connect $OSAKA"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open || die "a connect must close the popout, for the keyring prompt"
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Osaka'
log "ok: a country with two configurations lists them, and one connects; the reopened popout names it"

click_word "$OFF"
await_called off
await_gone '^Connected$'
log "ok: Off turns the VPN off"

# Back to Japan, then Back, Tokyo, and its Forget are the first three stops of Tab, since Off is gone.
click_word --last '^Proton$'
click_word '^Japan$'
await_word '^Tokyo$'
vekrona-dev key tab
vekrona-dev key tab
vekrona-dev key tab
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Forget\s+this'
never_called "forget $TOKYO"
snap forget-confirmation
click_word --last '^Forget$'
await_called "forget $TOKYO"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open || die "a forget must close the popout, for the keyring"
[[ "$(stub_file list.json)" != *"$TOKYO"* ]] || die "forget must remove the configuration from the tool's list"
log "ok: Tab and Enter reach Forget, which asks first; the popout closes for the keyring and the tool no longer lists the configuration"

# Japan has one configuration left, so its row connects at once and carries its own Forget: Switzerland is the same, and at the
# vendor's level Back, Switzerland and its Forget are the first three stops of Tab.
reopen_popout
click_word --last '^Proton$'
await_word '^Switzerland$'
vekrona-dev key tab
vekrona-dev key tab
vekrona-dev key tab
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Forget\s+this'
# The question puts the keyboard on Cancel, whose focus frame OCR cannot read, so Enter answers it.
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent text_shown 'Forget\s+this'
never_called "forget $ZURICH"
await_word '^Switzerland$'
log "ok: Cancel keeps the configuration"

reopen_popout
click_word "$MULLVAD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'account\s+number'
absent word_shown '^Netherlands$' || die "Mullvad without an account must not offer its countries"
# The keyboard is in the field without a click: the popout asks for typing.
vekrona-dev type 9999
vekrona-dev key enter
# Logging in closes the popout (the keyring may prompt), so the refusal is a notification.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'unknown\s+account'
snap login-refused
reopen_popout
click_word "$MULLVAD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'account\s+number'
absent word_shown '^Netherlands$' || die "a wrong account number must not open Mullvad's countries"
vekrona-dev type "$ACCOUNT"
vekrona-dev key enter
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open || die "a login must close the popout, for the keyring"
[[ "$(stub_file login.stdin)" == "$ACCOUNT" ]] || die "the account number must reach the tool on its stdin, but it read: $(stub_file login.stdin)"
calls="$(vpn_calls)"
[[ "$calls" != *"$ACCOUNT"* ]] || die "the account number must not be in the arguments of any call"
reopen_popout
click_word "$MULLVAD"
await_word '^Netherlands$'
await_word '^Sweden$'
snap login-accepted
log "ok: the account field has the keyboard, a wrong number is refused in a notification, the right one goes over stdin and opens the countries"

click_word '^Netherlands$'
await_called "connect mullvad NL"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open || die "a connect must close the popout, for the keyring prompt"
log "ok: a Mullvad country connects by its code"

open_popout
click_word '^Import$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open
await_called "import --vendor proton"
log "ok: Import Proton closes the popout and calls the tool"

vekrona-dev run bash -c 'echo "no portal here" >"$HOME/.cache/vekrona-vpn-stub/import-fails"'
open_popout
click_word --last '^other'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open
await_called "import --vendor other"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'no\s+portal\s+here'
snap import-failed
log "ok: a failed import comes as a notification"

# A failed connect is a notification: the popout is closed by then, as it is for every connect.
vekrona-dev run bash -c 'echo "no key in the keyring" >"$HOME/.cache/vekrona-vpn-stub/connect-fails"'
open_popout
click_word --last '^Proton$'
click_word '^Switzerland$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open || die "a connect must close the popout, even when it fails"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'no\s+key\s+in\s+the\s+keyring'
snap connect-failed
vekrona-dev run bash -c 'rm -f "$HOME/.cache/vekrona-vpn-stub/connect-fails"'
log "ok: a failed connect from the popout comes as a notification"

# A click into the popout gives it the keyboard.
open_popout
click_word --last '^Proton$'
vekrona-dev key esc
await_word "$MULLVAD"
vekrona-dev key esc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- absent popout_open
log "ok: Esc at the top closes the popout"

vpn_stub_set status "$(vpn_status_json false up null true)"
vpn_announce
open_popout
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'Not\s+protected'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown 'kill\s+switch\s+is\s+off'
snap exposed
log "ok: a tunnel without the kill switch is said to be not protected, and why"
