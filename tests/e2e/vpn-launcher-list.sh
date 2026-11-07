#!/usr/bin/env bash
# Opening the launcher costs no `vekrona-vpn list`: the list can ask Mullvad for its relays, so it is read when the VPN view is
# entered and not before. The scenario (against the stand-in of tests/e2e/lib/vpn-popout.sh, which records its calls) opens and
# closes the launcher, then opens the VPN view by IPC and expects the list to have been read exactly once, when the view showed it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/vpn-popout.sh
source "$ROOT/tests/e2e/lib/vpn-popout.sh"

STEP_TIMEOUT_SEC=60
# The VPN view of the stand-in's list while Mullvad is logged out: the Off row, Zurich, Tokyo, Osaka and Office.
export VPN_VIEW_ROWS=5

list_calls() { vpn_calls | awk '$0 == "list" { n++ } END { print n + 0 }'; }
vpn_view_shown() { launcher_is ".view == \"Settings › VPN\" and .rows == $VPN_VIEW_ROWS"; }
export -f vpn_view_shown

cleanup() { run_cleanups close_launcher vpn_stub_remove; }

vekrona-dev session
trap cleanup EXIT
vpn_stub_install
vpn_stub_set list "$VPN_LIST"
vpn_stub_set status "$VPN_STATUS_OFF"

vekrona-dev sh qs -c vekrona-shell ipc call launcher toggle >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_open
close_launcher

vekrona-dev sh qs -c vekrona-shell ipc call launcher settings vpn >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vpn_view_shown || die "the VPN view must list the connections of the stand-in"
[[ "$(list_calls)" == 1 ]] || die "the list must be read once, by the VPN view, but the tool saw $(list_calls) calls of list"
log "ok: the list is read when the VPN view is entered, not when the launcher opens"
