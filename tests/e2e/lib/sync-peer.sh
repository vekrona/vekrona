# shellcheck shell=bash
# Sourced by the Sync scenarios, after tests/lib.sh (so it lives in lib/, out of reach of a glob that runs every scenario).
# The other device is a second Syncthing in the guest, started under a HOME of its own (the XDG directories unset, so that
# everything it and vekrona-sync write lands under PEER_HOME), with its GUI on a socket of its own and its sync port on loopback
# 22001; the guest's own Syncthing keeps listening on 22000. Neither announces itself, so each side is given the other's address.
PEER_HOME=/tmp/vekrona-e2e-sync-peer
PEER_LISTEN=127.0.0.1:22001
MAIN_LISTEN=127.0.0.1:22000
SYNC_GUEST_PY="$VEKRONA_ROOT/tests/e2e/sync-guest.py"
export PEER_HOME PEER_LISTEN MAIN_LISTEN SYNC_GUEST_PY

# Runs a command in the guest as the other device.
peer() { vekrona-dev run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME "HOME=$PEER_HOME" "$@"; }
# REST calls of the guest's own Syncthing and of the other device's, as JSON on stdout.
main_rest() { vekrona-dev run python3 - rest "$@" <"$SYNC_GUEST_PY"; }
peer_rest() { peer python3 - rest "$@" <"$SYNC_GUEST_PY"; }
export -f peer main_rest peer_rest

# Starts a daemon of the other device in the background, in the desktop session (vekrona-sync notifies on its bus), and records
# its PID, so that peer_kill stops this one and not the guest's own syncthing or vekrona-sync, whose command lines are the same.
peer_spawn() {
  local name="$1"
  shift
  vekrona-dev spawn "$PEER_HOME.$name.log" -- bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$PEER_HOME.$name.pid" \
    env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME "HOME=$PEER_HOME" "$@"
}
peer_alive() { vekrona-dev run bash -c '[[ -e "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null' _ "$PEER_HOME.$1.pid"; }
peer_gone() { absent peer_alive "$1"; }
peer_kill() {
  vekrona-dev run bash -c 'if [[ -e "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; then kill "$(cat "$1")"; fi' _ "$PEER_HOME.$1.pid"
  vekrona-dev until --timeout 30 -- peer_gone "$1"
}
export -f peer_spawn peer_alive peer_gone peer_kill

peer_syncthing_answers() { peer_rest GET /rest/system/status >/dev/null; }
export -f peer_syncthing_answers
peer_syncthing_start() {
  peer_spawn syncthing syncthing serve --no-browser --no-upgrade
  vekrona-dev until --timeout 90 -- peer_syncthing_answers
}
# A fresh other device, running.
peer_start() {
  vekrona-dev run rm -rf "$PEER_HOME"
  vekrona-dev run mkdir -p "$PEER_HOME"
  peer env STNODEFAULTFOLDER=1 syncthing generate >/dev/null
  vekrona-dev run python3 - configure "$PEER_HOME" "$PEER_LISTEN" <"$SYNC_GUEST_PY"
  peer_syncthing_start
}
peer_stop() {
  peer_kill watch
  peer_kill syncthing
  vekrona-dev run rm -rf "$PEER_HOME" "$PEER_HOME.syncthing.log" "$PEER_HOME.syncthing.pid" "$PEER_HOME.watch.log" "$PEER_HOME.watch.pid"
}
export -f peer_syncthing_start peer_start peer_stop

# Each device lists the other as pending, and the guest's accepts: the other device trusts the guest from the start (it is given
# the guest's address), and the guest is given the other's address once it has accepted, which makes it dial at once.
# Uses MAIN_ID and PEER_ID.
device_pending_on_main() { [[ "$(main_rest GET /rest/cluster/pending/devices | jq --arg id "$PEER_ID" 'has($id)')" == true ]]; }
device_known_on_main() { [[ "$(main_rest GET /rest/config/devices | jq --arg id "$PEER_ID" 'any(.[]; .deviceID == $id)')" == true ]]; }
devices_connected() { [[ "$(main_rest GET /rest/system/connections | jq --arg id "$PEER_ID" '.connections[$id].connected')" == true ]]; }
export -f device_pending_on_main device_known_on_main devices_connected

# Makes the other device ask the guest to connect. Sets MAIN_ID and PEER_ID.
peer_asks_main() {
  MAIN_ID="$(main_rest GET /rest/system/status | jq -r .myID)"
  PEER_ID="$(peer_rest GET /rest/system/status | jq -r .myID)"
  export MAIN_ID PEER_ID
  peer_rest POST /rest/config/devices "$(jq -nc --arg id "$MAIN_ID" --arg addr "tcp://$MAIN_LISTEN" '{deviceID: $id, name: "guest", addresses: [$addr]}')" >/dev/null
  vekrona-dev until --timeout 90 -- device_pending_on_main
}
# After the guest accepted: it dials the other device.
main_dials_peer() {
  main_rest PATCH "/rest/config/devices/$PEER_ID" "$(jq -nc --arg addr "tcp://$PEER_LISTEN" '{addresses: [$addr]}')" >/dev/null
  vekrona-dev until --timeout 90 -- devices_connected
}
# Puts the guest's Syncthing back, whatever step a failed run stopped at: every folder that is shared with the other device, the
# device itself once it is accepted, and what the other device offered or asked while it was still pending, are removed.
main_forget_peer() {
  [[ -n "${PEER_ID:-}" ]] || return 0
  local folder
  for folder in $(main_rest GET /rest/config/folders | jq -r --arg id "$PEER_ID" '.[] | select(any(.devices[]; .deviceID == $id)) | .id'); do
    main_rest DELETE "/rest/config/folders/$folder" >/dev/null
  done
  if device_known_on_main; then
    main_rest DELETE "/rest/config/devices/$PEER_ID" >/dev/null
  fi
  for folder in $(main_rest GET /rest/cluster/pending/folders | jq -r --arg id "$PEER_ID" 'to_entries[] | select(.value.offeredBy | has($id)) | .key'); do
    main_rest DELETE "/rest/cluster/pending/folders?folder=$folder&device=$PEER_ID" >/dev/null
  done
  if device_pending_on_main; then
    main_rest DELETE "/rest/cluster/pending/devices?device=$PEER_ID" >/dev/null
  fi
}
export -f peer_asks_main main_dials_peer main_forget_peer
