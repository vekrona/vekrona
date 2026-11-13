# shellcheck shell=bash
# shellcheck disable=SC2034 # a library: each consumer uses some of the names
# What the shell side knows about the system tor that Tor Browser reaches. One definition for bin/vekrona-tor-browser,
# libexec/vekrona-tor-prepare, libexec/vekrona-tor-route, stages 40, 50 and 70 and the Tor scenarios of tests/e2e, which source it.
# Files that cannot source it spell the same values and must be kept equal to them: etc/tor/torrc.d/vekrona.conf,
# etc/systemd/system/tor.service.d/vekrona.conf and etc/sysusers.d/vekrona-tor.conf (tests/stages/test-tor-config.sh reads them
# and fails when they differ), and lib/vekrona_vpn.py, which spells the user's name (TOR_USER; tests/vpn/test_vpn.py checks it).

# The user of the system tor (Fedora's package creates it; its sysusers.d entry has the name).
VEKRONA_TOR_USER=toranon
# The group the session user joins to reach the socket of tor; the login that lacks it needs a new login.
VEKRONA_TOR_GROUP=vekrona-tor
# The directory of the SOCKS socket (made by libexec/vekrona-tor-prepare when tor starts) and the socket in it. Tor Browser's
# sandbox binds the directory whole, so a tor restart's new socket is still seen.
VEKRONA_TOR_SOCKET_DIR=/run/vekrona-tor
VEKRONA_TOR_SOCKET="$VEKRONA_TOR_SOCKET_DIR/socks"
