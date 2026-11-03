#!/usr/bin/env bash
# A window that closes while the shell's Sway connection is down sends the shell no close event. The switcher re-reads Sway's tree
# when the connection comes back, and that must drop the window and keep the recency of the others, so that Super+Tab never
# picks the dead window. A window that closes while that read is still running must not come back with its answer either.
# The only reconnect Quickshell has follows a fatal IPC error, which Sway never causes. So the shell talks to Sway through a relay
# (sway-ipc-gap-proxy.py) that can swallow what Sway sends for a while and then break the shell's connections with bytes that
# are no IPC frame, and that can keep back Sway's answers to get_tree while its events pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30
GUEST_PROXY=/mnt/vekrona/tests/e2e/sway-ipc-gap-proxy.py
PROXY_SOCKET=/tmp/vekrona-e2e-sway-ipc-gap.sock
PROXY_STATE=/tmp/vekrona-e2e-sway-ipc-gap.state
PROXY_LOG=/tmp/vekrona-e2e-sway-ipc-gap.log
export PROXY_STATE

proxy_state() { vekrona-dev run cat "$PROXY_STATE"; }
proxy_mode_is() {
  local mode
  read -r mode _ <<<"$(proxy_state)"
  [[ "$mode" == "$1" ]]
}
# Whether the relay keeps back an answer to every get_tree the shell asked during the hold, and to at least one.
proxy_holds_every_tree() { [[ "$(proxy_state)" =~ ^hold\ asked=([1-9][0-9]*)\ held=([0-9]+) ]] && ((BASH_REMATCH[1] == BASH_REMATCH[2])); }
proxy_passed_a_close() { [[ "$(proxy_state)" =~ closes=[1-9] ]]; }
# The apps the switcher would list, most recent first, as compact JSON.
switcher_apps() { vekrona-dev sh qs -c vekrona-shell ipc call appswitch apps | jq -c .; }
switcher_apps_are() { [[ "$(switcher_apps)" == "$1" ]]; }
export -f proxy_state proxy_mode_is proxy_holds_every_tree proxy_passed_a_close switcher_apps switcher_apps_are

# Sway's socket, which the session puts in $SWAYSOCK of the user manager (Sway sets no $I3SOCK); vekrona-dev sh finds it the same way.
SWAY_SOCKET="$(vekrona-dev sh printenv SWAYSOCK)"
# Quickshell connects to $I3SOCK, swaymsg (which the shell runs for get_tree) to $SWAYSOCK, so the shell started with both set meets
# the relay. The relay itself and the scenario's swaymsg keep using Sway's socket.
route_shell_through_relay() {
  vekrona-dev run systemctl --user set-environment "I3SOCK=$PROXY_SOCKET" "SWAYSOCK=$PROXY_SOCKET"
  restart_shell
}
route_shell_to_sway() {
  vekrona-dev run systemctl --user unset-environment I3SOCK
  vekrona-dev run systemctl --user set-environment "SWAYSOCK=$SWAY_SOCKET"
  restart_shell
}

cleanup() {
  run_cleanups 'key_event up meta_l' route_shell_to_sway "kill_guest -f '[s]way-ipc-gap-proxy.py'" 'kill_guest -x foot' "vekrona-dev run rm -f $PROXY_SOCKET $PROXY_STATE"
}
trap cleanup EXIT

vekrona-dev session
kill_guest -x foot
vekrona-dev move 600 500
vekrona-dev session

vekrona-dev spawn "$PROXY_LOG" -- python3 -B "$GUEST_PROXY" "$PROXY_SOCKET" "$PROXY_STATE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proxy_mode_is relay || die "the relay never came up: $(vekrona-dev run cat "$PROXY_LOG")"
route_shell_through_relay

# The apps are focused in this order, so the switcher lists them as reseed-d, reseed-c, reseed-b, reseed-a.
for app in reseed-a reseed-b reseed-c reseed-d; do
  vekrona-dev spawn "/tmp/vekrona-e2e-$app.log" -- foot --app-id="$app"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is "$app" || die "$app never took focus; focused app: $(focused_app_id)"
done
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- switcher_apps_are '["reseed-d","reseed-c","reseed-b","reseed-a"]' \
  || die "the switcher must follow the windows through the relay, but it lists $(switcher_apps)"

# reseed-c closes while the shell hears nothing from Sway.
kill_guest -USR1 -f '[s]way-ipc-gap-proxy.py'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proxy_mode_is gap || die "the relay never opened its gap"
vekrona-dev sh swaymsg '[app_id="reseed-c"] kill' >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_closed reseed-c || die "reseed-c never closed"
switcher_apps_are '["reseed-d","reseed-c","reseed-b","reseed-a"]' || die "the gap must hide the close from the shell, but the switcher lists $(switcher_apps)"

# The relay breaks the shell's connections; Quickshell connects again and the switcher reads the tree.
kill_guest -USR2 -f '[s]way-ipc-gap-proxy.py'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- switcher_apps_are '["reseed-d","reseed-b","reseed-a"]' \
  || die "after the reconnect the switcher must list the windows of the tree in their old order, but it lists $(switcher_apps)"
log "ok: the reconnect drops the window that closed meanwhile and keeps the order of the others"

# The dead window was second in the old order, so a switcher that kept it would focus nothing and leave the focus on reseed-d.
key_event down meta_l
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- super_recorded_down || die "xremap must record Super as down while it is held"
key_tap tab
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- mode_is appswitch || die "the open switcher must put sway in the appswitch mode, but it is in '$(binding_mode)'"
key_event up meta_l
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- focused_is reseed-b || die "Super+Tab must pick reseed-b, the most recent window that is left, but the focus is on $(focused_app_id)"
log "ok: Super+Tab skips the window that closed during the gap"

# reseed-d closes while the shell waits for the tree it asked for after a reconnect. The answer predates the close and still holds
# reseed-d, so a switcher that took it as the list would bring the window back from the dead.
kill_guest -HUP -f '[s]way-ipc-gap-proxy.py'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proxy_mode_is hold || die "the relay never started its hold"
kill_guest -USR2 -f '[s]way-ipc-gap-proxy.py'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proxy_holds_every_tree || die "the shell must ask for the tree after the reconnect, but the relay reports $(proxy_state)"
vekrona-dev sh swaymsg '[app_id="reseed-d"] kill' >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_closed reseed-d || die "reseed-d never closed"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proxy_passed_a_close || die "the relay must pass reseed-d's close event on, but it reports $(proxy_state)"
kill_guest -ALRM -f '[s]way-ipc-gap-proxy.py'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- proxy_mode_is relay || die "the relay never ended its hold"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- switcher_apps_are '["reseed-b","reseed-a"]' \
  || die "a window that closed while the tree was read must stay out of the switcher, but it lists $(switcher_apps)"
log "ok: a tree that answers after a close does not bring the closed window back"
