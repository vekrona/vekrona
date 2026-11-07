#!/usr/bin/env bash
# Tor Browser's sandbox has no network of its own and reaches the internet only through the system tor: inside the Flatpak the only
# interface is lo, the SOCKS socket TOR_SOCKS_IPC_PATH names is the way out (check.torproject.org answers IsTor through it), it
# leads nowhere while tor is stopped, and `vekrona-tor-browser` ends tor with the browser (tor is not enabled at boot). What the VPN
# changes for it (nothing) is in tor-bypass.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/tor-guest.sh
source "$ROOT/tests/e2e/lib/tor-guest.sh"

vekrona-dev session
trap 'run_cleanups stop_tor' EXIT
require_tor_browser
stop_tor
vekrona-dev until --timeout "$TOR_STEP_TIMEOUT_SEC" -- tor_inactive

interfaces="$(sandbox_interfaces)"
[[ "$interfaces" == lo ]] || die "the Tor Browser sandbox must have lo and nothing else, but it has: $(tr '\n' ' ' <<<"$interfaces")"
log "ok: the sandbox has only lo"

status=0
sandbox_socks_check >/dev/null 2>&1 || status=$?
((status == NO_SOCKET_STATUS)) || die "with tor stopped, the socket check must fail with $NO_SOCKET_STATUS (nobody on the socket), but it exited $status"
log "ok: the sandbox reaches nothing while tor is stopped"

start_tor
vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- sandbox_reaches_tor || die "the sandbox must reach check.torproject.org through the tor socket, and the answer must say IsTor; last attempt: $(sandbox_socks_check 2>&1 | tail -n 3 || true)"
log "ok: check.torproject.org says the sandbox is on tor"

# tor opens a SOCKS port on 127.0.0.1:9050 by default; torrc.d/vekrona.conf names a socket instead, so nothing of tor listens on TCP and no
# local program can send traffic through tor around the kill switch.
listeners="$(vekrona-dev run sudo ss -ltnpH)" || abort "ss failed in the guest"
[[ "$listeners" != *'"tor"'* ]] || die "tor must listen on no TCP port, but the guest has: $(grep '"tor"' <<<"$listeners")"
log "ok: tor listens on no TCP port"

stop_tor
vekrona-dev until --timeout "$TOR_STEP_TIMEOUT_SEC" -- tor_inactive
# The wrapper starts tor, runs the launcher (--help prints its usage and returns) and stops tor again. It runs as a child of sway,
# since polkit lets the wheel user start and stop tor.service only from the session at the machine, which a login over ssh is not.
WRAPPER_OUT=/tmp/vekrona-e2e-tor-wrapper.out
export WRAPPER_OUT
wrapper_ended() { vekrona-dev run grep -q '^exit=' "$WRAPPER_OUT"; }
export -f wrapper_ended
vekrona-dev run rm -f "$WRAPPER_OUT"
vekrona-dev sh swaymsg exec "bash -c 'vekrona-tor-browser run --help >$WRAPPER_OUT 2>&1; echo exit=\$? >>$WRAPPER_OUT'" >/dev/null
vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- wrapper_ended || die "vekrona-tor-browser run --help must end"
vekrona-dev run grep -qx 'exit=0' "$WRAPPER_OUT" || die "vekrona-tor-browser run --help must run the launcher with tor up and exit 0: $(vekrona-dev run cat "$WRAPPER_OUT")"
tor_inactive || die "vekrona-tor-browser must stop tor when its Tor Browser has ended"
log "ok: vekrona-tor-browser leaves tor stopped"
