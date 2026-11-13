#!/usr/bin/env bash
# The VPN icon of the bar is one pictogram in the slot of its neighbours and shows what `vekrona-vpn status` says: another icon
# for off, for a tunnel coming up, for a tunnel that is up behind the kill switch, for a tunnel that is up without the kill switch (one
# brought up outside vekrona-vpn: it must not look protected), for traffic that the kill switch holds back while there is no tunnel,
# and for a tool that cannot say (the bar must not claim "off" then), which is also what it shows before the first answer. None of them moves (a turning icon is a timer that wakes the
# laptop), and a change of the state file the root helper writes is enough to change the icon. A stand-in for vekrona-vpn answers
# (tests/e2e/lib/vpn-popout.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/bar-widget.sh
source "$ROOT/tests/e2e/lib/bar-widget.sh"
# shellcheck source=lib/vpn-popout.sh
source "$ROOT/tests/e2e/lib/vpn-popout.sh"

STEP_TIMEOUT_SEC=90
STILL_LOOKS=6
CONNECTION='{"uuid":"11111111-1111-1111-1111-111111111111","vendor":"proton","country":"CH","name":"Zurich","ipv6":true}'
CENTRE=
export CENTRE

# The icon's pixels, around the column where the icon was found, and whether the icon looks like the ones of an earlier look (the
# pixels of the same icon differ by a level or two between screenshots, see bar-widget.py).
look() { bar_widget pixels "$CENTRE"; }
looks_like() { bar_widget near "$CENTRE" "$1"; }
looks_unlike() { ! looks_like "$1"; }
export -f look looks_like looks_unlike
# The VPN icon is the fifth widget from the right of the bar (bar-widget.py's FROM_RIGHT), whatever number of widgets the bar has.
vpn_icon_is_a_pictogram() {
  local widgets
  widgets="$(bar_widget kinds)"
  [[ "${widgets:$((${#widgets} - 5)):1}" == P ]]
}
# Every one of the next STILL_LOOKS looks, back to back, is $1.
holds_still() {
  local i
  for ((i = 0; i < STILL_LOOKS; i++)); do
    looks_like "$1" || return 1
  done
}

declare -A LOOK_OF=()
# Runs the rest of the arguments after the second to make the stub answer (vpn_stub_set status JSON, or vpn_stub_break_status for
# nothing, so that `status` fails), announces it, waits for the icon to change from the look $2 (none for the first state), and
# records what the icon of the state $1 looks like.
show_state() {
  local name="$1" previous="$2"
  shift 2
  "$@"
  vpn_announce
  if [[ -n "$previous" ]]; then
    vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- looks_unlike "$previous" || die "the VPN icon must change when the state becomes $name"
  fi
  for earlier in "${!LOOK_OF[@]}"; do
    looks_unlike "${LOOK_OF[$earlier]}" || die "the VPN icon of the state $name must look different from the one of $earlier"
  done
  LOOK_OF[$name]="$(look)"
  vpn_icon_is_a_pictogram || die "the VPN icon must be a pictogram in the state $name"
  holds_still "${LOOK_OF[$name]}" || die "the VPN icon must stand still in the state $name"
  snap "icon-$name"
  log "ok: $name is shown by an icon that is a pictogram and stands still"
}

cleanup() { run_cleanups vpn_stub_remove; }

vekrona-dev session
trap cleanup EXIT
clear_notifications
vpn_stub_install
vpn_stub_set list "$VPN_LIST"
vpn_stub_set status "$VPN_STATUS_OFF"
# The pointer, which an earlier scenario may have left over the icon, would hide part of it.
vekrona-dev move 640 400
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_widget center vpn >/dev/null || die "the bar must show the VPN icon"
read -r CENTRE _ <<<"$(bar_widget center vpn)"
export CENTRE

show_state off "" vpn_stub_set status "$VPN_STATUS_OFF"
show_state activating "${LOOK_OF[off]}" vpn_stub_set status "$(vpn_status_json true activating "$CONNECTION" false)"
show_state on "${LOOK_OF[activating]}" vpn_stub_set status "$(vpn_status_json true up "$CONNECTION" false)"
show_state exposed "${LOOK_OF[on]}" vpn_stub_set status "$(vpn_status_json false up "$CONNECTION" false)"
show_state blocked "${LOOK_OF[exposed]}" vpn_stub_set status "$(vpn_status_json true down "$CONNECTION" false)"
show_state unknown "${LOOK_OF[blocked]}" vpn_stub_break_status

log "ok: the six states have six different icons"

vpn_stub_set status "$VPN_STATUS_OFF"
vpn_announce
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- looks_like "${LOOK_OF[off]}" || die "once the tool answers again, the icon must be the off one"
log "ok: when the tool answers again the icon is the off one"

# A shell that has not had its first answer yet knows nothing: it shows the unknown icon, not the off one.
vpn_stub_hold_status
restart_shell
vekrona-dev move 640 400
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_widget center vpn >/dev/null || die "the bar must show the VPN icon after the restart"
read -r CENTRE _ <<<"$(bar_widget center vpn)"
export CENTRE
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- looks_like "${LOOK_OF[unknown]}" || die "before the first answer of the tool the icon must be the unknown one"
vpn_stub_release_status
# The announcement asks again in case the shell gave up on the held answer (its timeout) meanwhile.
vpn_announce
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- looks_like "${LOOK_OF[off]}" || die "once the first answer came, the icon must be the off one"
log "ok: before the first answer the icon is the unknown one, after it the off one"
