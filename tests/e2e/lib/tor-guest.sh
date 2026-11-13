# shellcheck shell=bash
# shellcheck disable=SC2034 # sourced by the Tor scenarios: each one uses some of the names
# Sourced by the Tor scenarios, after tests/lib.sh (so it lives in lib/, out of reach of a glob that runs every scenario). It drives
# tor and Tor Browser's sandbox in the guest; lib/tor.sh at the top of the repo is the other thing, the names the shell side of
# vekrona knows about tor.
# tor builds its first circuits in the time of a bootstrap; a loaded VM needs the margin.
TOR_UP_TIMEOUT_SEC=240
TOR_STEP_TIMEOUT_SEC=60
TOR_BROWSER_APP=org.torproject.torbrowser-launcher
NO_SOCKET_STATUS=3

# tor.service is started and stopped as root here: a command of `vekrona-dev run` is a login over ssh, which polkit does not count as a
# local session at the machine, so its rule for the wheel user does not apply (the wrapper vekrona-tor-browser is run in the session instead).
tor_active() { vekrona-dev run systemctl is-active --quiet tor.service; }
start_tor() { vekrona-dev run sudo systemctl start tor.service; }
tor_inactive() { inactive tor_active; }
stop_tor() { vekrona-dev run sudo systemctl stop tor.service; }
require_tor_browser() { vekrona-dev run flatpak info --system "$TOR_BROWSER_APP" >/dev/null || die "$TOR_BROWSER_APP must be installed system-wide"; }

# Tor Browser's sandbox is a scope of the user manager, `app-flatpak-<app ID escaped by systemd>-<instance>.scope`, active for as long as
# the browser runs. `flatpak ps` is not used: it lists instances whose processes have ended. The unit's name is made in the guest, where
# systemd is. Prints the active scopes of Tor Browser, one per line.
tor_browser_scopes() {
  local escaped listing unit
  escaped="$(vekrona-dev run systemd-escape "$TOR_BROWSER_APP")" || abort "cannot escape the app ID $TOR_BROWSER_APP in the guest"
  listing="$(vekrona-dev sh systemctl --user list-units --state=active --type=scope --plain --no-legend --no-pager)" \
    || abort "cannot list the active user scopes"
  while read -r unit _; do
    [[ "$unit" == "app-flatpak-$escaped-"*.scope ]] && printf '%s\n' "$unit"
  done <<<"$listing"
  return 0
}
tor_browser_running() { [[ -n "$(tor_browser_scopes)" ]]; }
tor_browser_stopped() { ! tor_browser_running; }
export -f tor_browser_scopes tor_browser_running tor_browser_stopped

# Runs inside the sandbox and asks check.torproject.org through the SOCKS socket (SOCKS5, host name resolved by tor). Exit 0: the
# answer says the request came through tor; NO_SOCKET_STATUS: nobody listens on the socket; anything else: tor answered with a failure.
SOCKS_CHECK="$(
  cat <<PY
import json, os, socket, ssl, struct, sys

def read_exactly(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            sys.exit("the socket closed after %d of %d bytes" % (len(data), n))
        data += chunk
    return data

s = socket.socket(socket.AF_UNIX)
s.settimeout(60)
try:
    s.connect(os.environ["TOR_SOCKS_IPC_PATH"])
except OSError as error:
    print("no tor on the socket:", error, file=sys.stderr)
    sys.exit($NO_SOCKET_STATUS)
s.sendall(b"\x05\x01\x00")
if read_exactly(s, 2) != b"\x05\x00":
    sys.exit("tor refused the SOCKS5 greeting")
host = b"check.torproject.org"
s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + struct.pack(">H", 443))
reply = read_exactly(s, 4)
if reply[1] != 0:
    sys.exit("SOCKS5 error %d" % reply[1])
# The reply ends with the address tor bound for the connection, whose length depends on its type, and a port.
read_exactly(s, {1: 4, 4: 16}.get(reply[3], 0) + (read_exactly(s, 1)[0] if reply[3] == 3 else 0) + 2)
s = ssl.create_default_context().wrap_socket(s, server_hostname=host.decode())
s.sendall(b"GET /api/ip HTTP/1.0\r\nHost: check.torproject.org\r\n\r\n")
answer = b""
while True:
    chunk = s.recv(4096)
    if not chunk:
        break
    answer += chunk
sys.exit(0 if json.loads(answer.split(b"\r\n\r\n", 1)[1])["IsTor"] else "check.torproject.org says this is not tor")
PY
)"

# Runs the check in the sandbox; its exit status is the check's.
sandbox_socks_check() { vekrona-dev run flatpak run --command=python3 "$TOR_BROWSER_APP" -P -c "$SOCKS_CHECK"; }
sandbox_reaches_tor() { sandbox_socks_check 2>/dev/null; }
sandbox_interfaces() {
  local table
  table="$(vekrona-dev run flatpak run --command=cat "$TOR_BROWSER_APP" /proc/net/dev)" || abort "cannot read /proc/net/dev in the sandbox"
  awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }' <<<"$table"
}
export -f tor_active tor_inactive sandbox_socks_check sandbox_reaches_tor
export TOR_BROWSER_APP SOCKS_CHECK
