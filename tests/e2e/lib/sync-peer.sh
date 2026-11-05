# shellcheck shell=bash
# Sourced by the Sync scenarios, after tests/lib.sh (so it lives in lib/, out of reach of a glob that runs every scenario).
#
# The other device is a second Syncthing in the guest, a phone as far as the guest's own Syncthing can tell: it runs in a network
# namespace of its own (PEER_NETNS) that a veth pair connects to the guest on 10.77.0.0/24, so that local discovery broadcasts
# cross between the two as they do on a LAN, and nothing else does (the other device has no global discovery, relays or NAT).
# Its HOME is PEER_HOME, with the XDG directories unset, so that everything it and vekrona-sync write lands there, and its GUI is
# a socket of its own. The scenarios never tell either device the ID of the other: they find each other through discovery, a
# pairing request, or what a person would copy from the screen. They do read IDs, to check what happened.
PEER_HOME=/tmp/vekrona-e2e-sync-peer
PEER_NETNS=vkpeer
PEER_EXEC="$PEER_HOME.exec"
SYNC_GUEST_PY="$VEKRONA_ROOT/tests/e2e/sync-guest.py"
export PEER_HOME PEER_NETNS PEER_EXEC SYNC_GUEST_PY

# Runs a command in the guest as the other device (not in its network namespace, which only its Syncthing needs).
peer() { vekrona-dev run env -u XDG_STATE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME "HOME=$PEER_HOME" "$@"; }
# REST calls of the guest's own Syncthing and of the other device's, as JSON on stdout.
main_rest() { vekrona-dev run python3 - rest "$@" <"$SYNC_GUEST_PY"; }
peer_rest() { peer python3 - rest "$@" <"$SYNC_GUEST_PY"; }
export -f peer main_rest peer_rest

peer_net_up() {
  vekrona-dev run sudo bash -c '
    set -euo pipefail
    ip netns add "$1"
    ip link add vkm0 type veth peer name vkp0
    ip link set vkp0 netns "$1"
    ip addr add 10.77.0.1/24 broadcast 10.77.0.255 dev vkm0
    ip link set vkm0 up
    ip netns exec "$1" ip addr add 10.77.0.2/24 broadcast 10.77.0.255 dev vkp0
    ip netns exec "$1" ip link set vkp0 up
    ip netns exec "$1" ip link set lo up' _ "$PEER_NETNS"
}
# Deleting the namespace destroys the far end of the veth pair, and with it the near end, once nothing runs in it any more.
peer_net_down() {
  vekrona-dev run sudo bash -c 'if [[ -e "/run/netns/$1" ]]; then ip netns pids "$1" | xargs --no-run-if-empty kill; ip netns del "$1"; fi' _ "$PEER_NETNS"
}

# Starts a daemon of the other device in the background, in the desktop session (vekrona-sync notifies on its bus) and its
# network namespace, and records its PID, so that peer_kill stops this one and not the guest's own syncthing or vekrona-sync,
# whose command lines are the same.
peer_spawn() {
  local name="$1"
  shift
  vekrona-dev spawn "$PEER_HOME.$name.log" -- bash "$PEER_EXEC" "$PEER_NETNS" "$PEER_HOME" "$PEER_HOME.$name.pid" "$@"
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
  peer_spawn syncthing syncthing serve --no-browser --no-upgrade --no-restart
  vekrona-dev until --timeout 90 -- peer_syncthing_answers
}
# A key and a configuration for the other device, which makes it a new device with an ID of its own.
peer_identity() {
  vekrona-dev run rm -rf "$PEER_HOME/.local/state/syncthing" "$PEER_HOME/.config/syncthing"
  peer env STNODEFAULTFOLDER=1 syncthing generate >/dev/null
  vekrona-dev run python3 - configure "$PEER_HOME" <"$SYNC_GUEST_PY"
}
# A fresh other device on its own network, running.
peer_start() {
  peer_net_down
  peer_net_up
  vekrona-dev run rm -rf "$PEER_HOME"
  vekrona-dev run mkdir -p "$PEER_HOME"
  guest_write "$VEKRONA_ROOT/tests/e2e/lib/sync-peer-exec.sh" "$PEER_EXEC"
  peer_identity
  peer_syncthing_start
}
# The same device with a new identity, as a different one that arrives.
peer_replace() {
  peer_kill syncthing
  peer_identity
  peer_syncthing_start
}
peer_stop() {
  peer_kill watch
  peer_kill syncthing
  peer_net_down
  vekrona-dev run rm -rf "$PEER_HOME" "$PEER_HOME".*
}
export -f peer_identity peer_start peer_replace peer_stop

peer_id() { peer_rest GET /rest/system/status | jq -r .myID; }
export -f peer_id

# What the other device sees of the guest, as a phone would: a pairing request it accepts the way a person taps "Add device",
# and a folder offer it accepts the way a person taps "Accept". It never knows an ID that it did not receive from the guest.
peer_pending_device() { peer_rest GET /rest/cluster/pending/devices | jq -r 'keys[0] // empty'; }
peer_has_pending_device() { [[ -n "$(peer_pending_device)" ]]; }
peer_accepts_pending_device() {
  local pending name
  pending="$(peer_pending_device)"
  [[ -n "$pending" ]] || die "the other device has no pairing request to accept"
  name="$(peer_rest GET /rest/cluster/pending/devices | jq -r --arg id "$pending" '.[$id].name')"
  peer_rest POST /rest/config/devices "$(jq -nc --arg id "$pending" --arg name "$name" '{deviceID: $id, name: $name}')" >/dev/null
}
# Asks the guest to connect, with an ID that a person got from somewhere else (the QR code, a typed one): $1.
peer_adds_device() {
  peer_rest POST /rest/config/devices "$(jq -nc --arg id "$1" '{deviceID: $id, name: "guest"}')" >/dev/null
}
# The folders that a device offers the other device, by ID.
peer_offered_folders() { peer_rest GET /rest/cluster/pending/folders | jq -r 'keys[]'; }
peer_folder_offered() { [[ "$(peer_rest GET /rest/cluster/pending/folders | jq --arg id "$1" 'has($id)')" == true ]]; }
export -f peer_pending_device peer_has_pending_device peer_offered_folders peer_folder_offered
# Joins the offered folder $1, at ~/Sync/$2 of the other device, shared with the devices that offer it.
peer_joins_folder() {
  local offer defaults
  offer="$(peer_rest GET /rest/cluster/pending/folders | jq -c --arg id "$1" '.[$id].offeredBy')"
  defaults="$(peer_rest GET /rest/config/defaults/folder)"
  peer_rest POST /rest/config/folders "$(jq -nc --argjson defaults "$defaults" --argjson offer "$offer" --arg id "$1" --arg label "$2" \
    --arg path "$PEER_HOME/Sync/$2" --arg me "$(peer_id)" \
    '$defaults + {id: $id, label: $label, path: $path, type: "sendreceive", devices: ([$me] + ($offer | keys) | map({deviceID: .}))}')" >/dev/null
}
# Shares the directory ~/$1 of the other device with every device it knows.
peer_shares_folder() {
  local defaults
  defaults="$(peer_rest GET /rest/config/defaults/folder)"
  peer_rest POST /rest/config/folders "$(jq -nc --argjson defaults "$defaults" --arg id "peer-$1" --arg label "$1" --arg path "$PEER_HOME/$1" \
    --argjson known "$(peer_rest GET /rest/config/devices)" \
    '$defaults + {id: $id, label: $label, path: $path, type: "sendreceive", devices: ($known | map({deviceID: .deviceID}))}')" >/dev/null
}
peer_device_connected() { [[ "$(peer_rest GET /rest/system/connections | jq '[.connections[] | select(.connected)] | length')" -ge 1 ]]; }
export -f peer_accepts_pending_device peer_adds_device peer_joins_folder peer_shares_folder peer_device_connected

# The guest's own side.
main_id() { main_rest GET /rest/system/status | jq -r .myID; }
device_known_on_main() { [[ "$(main_rest GET /rest/config/devices | jq --arg id "$1" 'any(.[]; .deviceID == $id)')" == true ]]; }
device_ignored_on_main() { [[ "$(main_rest GET /rest/config | jq --arg id "$1" 'any(.remoteIgnoredDevices[]; .deviceID == $id)')" == true ]]; }
device_pending_on_main() { [[ "$(main_rest GET /rest/cluster/pending/devices | jq --arg id "$1" 'has($id)')" == true ]]; }
device_connected_on_main() { [[ "$(main_rest GET /rest/system/connections | jq --arg id "$1" '.connections[$id].connected')" == true ]]; }
export -f main_id device_known_on_main device_ignored_on_main device_pending_on_main device_connected_on_main

# sync.json of the guest, and whether it satisfies a jq test (with $peer and $folder from PEER_ID and SHARED_ID); a state file
# that is not there yet is a no.
state_json() { vekrona-dev run bash -c 'cat "$HOME/.local/state/vekrona/sync.json"'; }
state_is() { state_json 2>/dev/null | jq -e --arg peer "${PEER_ID:-}" --arg folder "${SHARED_ID:-}" "$1" >/dev/null; }
watcher_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-sync.service; }
export -f state_json state_is watcher_active

# The guest's Syncthing with nothing of the other devices: no device, no folder shared with one, no request, no ignored device
# (Syncthing keeps the devices it heard by discovery until it restarts, and the Nearby list shows them: main_syncthing_restart
# forgets those), so each scenario starts from the same list.
main_forget_peers() {
  local folder device
  for folder in $(main_rest GET /rest/config/folders | jq -r --arg me "$(main_id)" '.[] | select(any(.devices[]; .deviceID != $me)) | .id'); do
    main_rest DELETE "/rest/config/folders/$folder" >/dev/null
  done
  for device in $(main_rest GET /rest/config/devices | jq -r --arg me "$(main_id)" '.[] | select(.deviceID != $me) | .deviceID'); do
    main_rest DELETE "/rest/config/devices/$device" >/dev/null
  done
  main_rest PUT /rest/config "$(main_rest GET /rest/config | jq -c '.remoteIgnoredDevices = []')" >/dev/null
  for device in $(main_rest GET /rest/cluster/pending/devices | jq -r 'keys[]'); do
    main_rest DELETE "/rest/cluster/pending/devices?device=$device" >/dev/null
  done
  main_rest GET /rest/cluster/pending/folders | jq -r 'to_entries[] | .key as $f | .value.offeredBy | keys[] | "\($f) \(.)"' |
    while read -r folder device; do main_rest DELETE "/rest/cluster/pending/folders?folder=$folder&device=$device" >/dev/null; done
}
invocation() { vekrona-dev sh systemctl --user show -p InvocationID --value syncthing.service; }
restarted_since() { [[ "$(invocation)" != "$1" ]]; }
main_answers() { main_rest GET /rest/system/status >/dev/null; }
export -f invocation restarted_since main_answers
main_syncthing_restart() {
  local before
  before="$(invocation)"
  vekrona-dev sh systemctl --user restart syncthing.service
  vekrona-dev until --timeout 90 -- restarted_since "$before"
  vekrona-dev until --timeout 90 -- main_answers
  vekrona-dev until --timeout 90 -- watcher_active
}
export -f main_forget_peers main_syncthing_restart
