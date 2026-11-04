#!/usr/bin/env bash
# Syncthing's GUI and REST API listen on a unix socket in a directory only the user can enter, with no login and no TCP port: the
# OS user is the authentication. Stage 50 writes the socket's address into config.xml, so a daemon started without the unit's
# drop-in uses the socket too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
WORK=/tmp/vekrona-e2e-syncthing-socket
SERVE_LOG="$WORK/serve.log"
# Connects to the socket named by the argument; a refusal by the kernel prints EACCES, and any other outcome is a failure.
CONNECT_AS='import socket, sys
s = socket.socket(socket.AF_UNIX)
try:
    s.connect(sys.argv[1])
except PermissionError:
    print("EACCES")
    sys.exit(0)
print("connected")
sys.exit(1)'

guest_uid="$(vekrona-dev run id -u)"
[[ "$guest_uid" =~ ^[0-9]+$ ]] || die "cannot read the uid of the guest user: '$guest_uid'"
SOCKET_DIR="/run/user/$guest_uid/syncthing"
SOCKET="$SOCKET_DIR/gui.sock"

# The REST API answers 403 "CSRF Error" to a request without the token the GUI page hands out, so the request carries the token
# (and no API key and no cookie of a login): only a login could refuse it then, which Syncthing does with 401 or 403.
anonymous_status() {
  vekrona-dev run bash -c '
jar="$(mktemp)"
curl -s -o /dev/null -c "$jar" --unix-socket "$1" http://localhost/
name="$(awk "/CSRF-Token/ { print \$6 }" "$jar")"
token="$(awk "/CSRF-Token/ { print \$7 }" "$jar")"
curl -s -o /dev/null -w "%{http_code}" -b "$jar" -H "X-$name: $token" --unix-socket "$1" http://localhost/rest/system/status
rm -f "$jar"' _ "$SOCKET"
}
gui_answers() { [[ "$(anonymous_status)" == 200 ]]; }
tcp_8384_free() { [[ -z "$(vekrona-dev run ss -Hltn 'sport = :8384')" ]]; }
socket_present() { vekrona-dev run test -S "$SOCKET"; }
socket_gone() { absent socket_present; }
syncthing_running() { vekrona-dev run pgrep -x syncthing >/dev/null; }
syncthing_gone() { absent syncthing_running; }
export -f anonymous_status gui_answers tcp_8384_free socket_present socket_gone syncthing_running syncthing_gone
export SOCKET

# Both the unit and a daemon of this scenario's own are stopped, and the second one is waited for: it holds the database, which
# the unit needs.
restore() {
  vekrona-dev sh systemctl --user stop syncthing.service
  kill_guest -x syncthing
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- syncthing_gone
  vekrona-dev run rm -rf "$WORK" "$SOCKET_DIR"
  vekrona-dev sh systemctl --user restart syncthing.service
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gui_answers
}
vekrona-dev session
trap 'run_cleanups restore' EXIT

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gui_answers || die "the Syncthing REST API does not answer on $SOCKET without a login"
log "ok: the REST API answers on the socket without a login"

config_file="$(vekrona-dev run bash -c 'syncthing paths | awk "/^Configuration file:/ { getline; print \$1; exit }"')"
vekrona-dev run grep -qF "<address>$SOCKET</address>" "$config_file" || die "$config_file does not hold $SOCKET as the GUI address"
log "ok: config.xml holds the socket as the GUI address, a bare absolute path"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tcp_8384_free || die "something listens on TCP port 8384"
log "ok: nothing listens on 8384"

[[ "$(vekrona-dev run stat -c '%U %a' "$SOCKET_DIR")" == "$(vekrona-dev run id -un) 700" ]] \
  || die "the socket's directory must belong to the user and be 0700: $(vekrona-dev run stat -c '%U %a' "$SOCKET_DIR")"
log "ok: the socket is in a 0700 directory of the user"

[[ "$(vekrona-dev run sudo -u nobody python3 -I -c "$CONNECT_AS" "$SOCKET")" == EACCES ]] || die "another user could open the socket"
log "ok: another uid gets EACCES"

# No unit and so no drop-in: the directory the drop-in makes is made by hand, and the daemon is started the way a user would.
vekrona-dev sh systemctl --user stop syncthing.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- socket_gone
vekrona-dev run bash -c 'mkdir -p "$1" && install -d -m 0700 "$2"' _ "$WORK" "$SOCKET_DIR"
vekrona-dev spawn "$SERVE_LOG" -- syncthing serve --no-browser --no-restart --no-upgrade
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gui_answers || die "a syncthing serve without the unit's drop-in does not serve its GUI on $SOCKET"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tcp_8384_free || die "a syncthing serve without the unit's drop-in opened TCP port 8384"
log "ok: syncthing serve without the drop-in uses the socket, not a TCP port"
