# shellcheck shell=bash
# Sourced by the VPN scenarios, after tests/lib.sh and lib/bar-widget.sh (so it lives in lib/, out of reach of a glob that runs every
# scenario). The scenarios need no tunnel and no provider: the bar's VPN pill and popout speak to `vekrona-vpn` and to nothing else, so
# a stand-in (tests/e2e/vpn-stub.py) takes its place in the guest's ~/.local/bin for the length of a scenario, and the scenario writes
# the answers it wants. The real tool is moved aside and put back. The shell follows /run/vekrona-vpn/state.json for changes, so a
# change of the answers is announced by writing that file, as the root helper does. POPOUT_SHOTS_DIR (words.sh) collects screenshots.
# shellcheck source=words.sh
source "$(dirname "${BASH_SOURCE[0]}")/words.sh"
VPN_STUB_PY="$VEKRONA_ROOT/tests/e2e/vpn-stub.py"
VPN_STATE_DIR=/run/vekrona-vpn
export VPN_STUB_PY VPN_STATE_DIR

# The layout of the answers (`"schema"`) is the backend's own number, read from its source, so that a scenario fails where the
# shell and the backend disagree about it (VpnState.schemaVersion).
VPN_SCHEMA="$(sed -n 's/^OUTPUT_SCHEMA = \([0-9][0-9]*\)$/\1/p' "$VEKRONA_ROOT/lib/vekrona_vpn.py")"
[[ "$VPN_SCHEMA" =~ ^[0-9]+$ ]] || die "cannot read OUTPUT_SCHEMA from lib/vekrona_vpn.py"

# What `vekrona-vpn status` prints: vpn_status_json ARMED TUNNEL CONNECTION LOGGED_IN, where ARMED and LOGGED_IN (Mullvad's) are true or
# false and CONNECTION is a JSON object or null. Proton is signed out.
vpn_status_json() {
  jq -nc --argjson schema "$VPN_SCHEMA" --argjson armed "$1" --arg tunnel "$2" --argjson connection "$3" --argjson logged_in "$4" \
    '{schema: $schema, armed: $armed, tunnel: $tunnel, connection: $connection, mullvad: {logged_in: $logged_in}, proton: {logged_in: false, netshield: 1, error: ""}}'
}
# The answers of a stub that has nothing connected and no Mullvad account.
VPN_STATUS_OFF="$(vpn_status_json false down null false)"
# Two Mullvad countries, a signed-out Proton (no countries), and imported configurations, which `list` gives only to "other": a country
# with one configuration, one with two, and one whose country the tool could not tell. The names are words that OCR reads.
VPN_LIST="$(jq -c --argjson schema "$VPN_SCHEMA" '{schema: $schema} + .' <<'JSON'
{"vendors":[
  {"id":"mullvad","label":"Mullvad","countries":[
    {"code":"NL","name":"Netherlands","load":null,"ipv6":true,"configs":[]},
    {"code":"SE","name":"Sweden","load":null,"ipv6":true,"configs":[]}]},
  {"id":"proton","label":"Proton VPN","countries":[]},
  {"id":"other","label":"Other","countries":[
    {"code":"CH","name":"Switzerland","load":null,"ipv6":null,"configs":[{"uuid":"11111111-1111-1111-1111-111111111111","name":"Zurich","ipv6":true}]},
    {"code":"JP","name":"Japan","load":null,"ipv6":null,"configs":[
      {"uuid":"22222222-2222-2222-2222-222222222222","name":"Tokyo","ipv6":true},
      {"uuid":"33333333-3333-3333-3333-333333333333","name":"Osaka","ipv6":true}]},
    {"code":"??","name":"Unknown","load":null,"ipv6":null,"configs":[{"uuid":"44444444-4444-4444-4444-444444444444","name":"Office","ipv6":true}]}]}]}
JSON
)"
export VPN_STATUS_OFF VPN_LIST

# Moves the real tool and the real state file aside, puts the stub in, and writes an empty state file, so that the shell has one
# to follow from its start; restart_shell then makes the shell meet the stub.
vpn_stub_install() {
  vekrona-dev run bash -c 'set -euo pipefail
    bin="$HOME/.local/bin/vekrona-vpn"
    mkdir -p "$HOME/.cache/vekrona-vpn-stub"
    rm -f "$HOME"/.cache/vekrona-vpn-stub/*
    if [[ ( -e "$bin" || -L "$bin" ) && ! -e "$bin.e2e-orig" && ! -L "$bin.e2e-orig" ]]; then mv "$bin" "$bin.e2e-orig"; fi
    cat >"$bin"
    chmod +x "$bin"' <"$VPN_STUB_PY"
  vekrona-dev run sudo bash -c 'set -euo pipefail
    install -d -m 755 "$1"
    if [[ -e "$1/state.json" && ! -e "$1/state.json.e2e-orig" ]]; then mv "$1/state.json" "$1/state.json.e2e-orig"; fi
    echo "{\"seq\":0}" >"$1/state.json"
    chmod 644 "$1/state.json"' _ "$VPN_STATE_DIR"
  restart_shell
}
vpn_stub_remove() {
  vekrona-dev run bash -c 'bin="$HOME/.local/bin/vekrona-vpn"
    if [[ -e "$bin.e2e-orig" || -L "$bin.e2e-orig" ]]; then mv -f "$bin.e2e-orig" "$bin"; else rm -f "$bin"; fi
    rm -rf "$HOME/.cache/vekrona-vpn-stub"'
  vekrona-dev run sudo bash -c 'if [[ -e "$1/state.json.e2e-orig" ]]; then mv -f "$1/state.json.e2e-orig" "$1/state.json"; else rm -f "$1/state.json"; fi' _ "$VPN_STATE_DIR"
  restart_shell
}

# vpn_stub_set status|list JSON: what the stub answers from now on, replaced whole (a write that is never half seen).
vpn_stub_set() {
  vekrona-dev run bash -c 'f="$HOME/.cache/vekrona-vpn-stub/$1.json"; printf "%s\n" "$2" >"$f.tmp" && mv "$f.tmp" "$f"' _ "$1" "$2"
}
# The stub's `status` fails from now on.
vpn_stub_break_status() { vekrona-dev run bash -c 'rm -f "$HOME/.cache/vekrona-vpn-stub/status.json"'; }
# From now on `status` waits (the stub's status.gate fifo) until vpn_stub_release_status, so that a scenario sees the shell before its
# first answer. Nothing sleeps: the stub blocks on opening the fifo.
vpn_stub_hold_status() { vekrona-dev run bash -c 'mkfifo "$HOME/.cache/vekrona-vpn-stub/status.gate"'; }
# Lets the waiting `status` answer and the later ones pass: the fifo is opened for writing (which ends the wait), then removed.
vpn_stub_release_status() {
  vekrona-dev run bash -c 'f="$HOME/.cache/vekrona-vpn-stub/status.gate"; exec 3<>"$f"; rm -f "$f"'
}
# Announces a change the way the root helper does: the state file is written. A write of the same text would be no change.
VPN_SEQ=0
vpn_announce() {
  VPN_SEQ=$((VPN_SEQ + 1))
  vekrona-dev run sudo bash -c 'printf "{\"seq\":%s}\n" "$2" >"$1/state.json"' _ "$VPN_STATE_DIR" "$VPN_SEQ"
}
# The arguments of every call the stub has seen, one call per line.
vpn_calls() { vekrona-dev run bash -c 'cat "$HOME/.cache/vekrona-vpn-stub/calls.log"'; }
# grep reads all of its input (no -q): with -q it could exit at the first match and leave vpn_calls with SIGPIPE, which pipefail reports.
vpn_called() { vpn_calls | grep -xF -- "$1" >/dev/null; }
export -f vpn_calls vpn_called

# A click on the pill toggles the popout (the first opens it, the second closes it).
click_vpn_pill() {
  local x y
  read -r x y <<<"$(bar_widget center vpn)"
  [[ -n "${x:-}" ]] || die "the bar must show the VPN icon"
  vekrona-dev click "$x" "$y"
}
