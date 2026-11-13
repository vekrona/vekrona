#!/usr/bin/env bash
# A person starts Tor Browser from the launcher where it has never been downloaded. The desktop entry runs `vekrona-tor-browser run`,
# which sets the launcher to download over tor: the Flatpak has no network, so the download goes through the system tor. The launcher
# then starts the browser, and tor runs only while the browser does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
# shellcheck source=lib/tor-guest.sh
source "$ROOT/tests/e2e/lib/tor-guest.sh"

STEP_TIMEOUT_SEC=60
# The download over tor took about eight minutes in the VM; this is generous for a loaded one.
DOWNLOAD_TIMEOUT_SEC=2700
# The download runs for minutes with nothing typed, and the idle lock would take the session meanwhile (TODO.md): the scenario holds
# it off for the whole run, as idle-suspend does.
CAFFEINE_SPAN=2h
# The launcher's own window has this app_id (Qt names it after the desktop file), so it is not the browser's window. The browser runs
# under XWayland, where its class is the one of the desktop entry's StartupWMClass.
BROWSER_WINDOW_FILTER='[.. | objects | select(((.app_id // .window_properties.class? // "") as $name | ($name | test("tor.?browser"; "i")) and $name != "org.torproject.torbrowser-launcher"))]'
export BROWSER_WINDOW_FILTER

browser_stopped() { tor_browser_stopped; }
# Whether the browser's window is open: 0 yes, 1 no, anything else is a failure of the query.
browser_window_open() {
  vekrona-dev sh bash -c 'set -o pipefail; swaymsg -t get_tree | jq -e "$1 | length > 0" >/dev/null' _ "$BROWSER_WINDOW_FILTER"
}
browser_window_or_stopped() { browser_window_open || browser_stopped; }
tor_browser_selected() { launcher_is ".selectedId | startswith(\"apps:$TOR_BROWSER_APP\")"; }
export -f browser_stopped browser_window_open browser_window_or_stopped tor_browser_selected

# Closes the browser's window as its close button does: sway asks the window to close.
close_browser_window() {
  vekrona-dev sh bash -c '
set -euo pipefail
id="$(swaymsg -t get_tree | jq -r "$1 | .[0].id")"
[[ "$id" != null ]] || { echo "no window of Tor Browser to close" >&2; exit 1; }
swaymsg "[con_id=$id] kill" >/dev/null
' _ "$BROWSER_WINDOW_FILTER"
}
kill_browser() { browser_stopped || vekrona-dev run flatpak kill "$TOR_BROWSER_APP"; }
caffeine_off() { vekrona-dev sh vekrona-caffeine off >/dev/null; }

# How many lines of the user journal since the epoch second $1 match the extended regex $2 (none is 0). A journalctl that fails is a
# failure, never "no match".
journal_count_since() {
  local log
  log="$(vekrona-dev run journalctl --user --no-pager -o cat --since "@$1")" || abort "cannot read the user journal"
  grep -cE "$2" <<<"$log" || [[ $? -eq 1 ]]
}
# Qt ends a process that destroys a QThread which still runs (during the download), and the launcher with it.
no_qthread_abort() {
  local count
  count="$(journal_count_since "$started_at" 'QThread: Destroyed')"
  [[ "$count" == 0 ]] || die "the launcher must not abort with 'QThread: Destroyed', but the journal has it $count times since the desktop entry started it"
}

vekrona-dev session
trap 'run_cleanups kill_browser caffeine_off stop_tor' EXIT
require_tor_browser
kill_browser
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- browser_stopped
stop_tor
vekrona-dev until --timeout "$TOR_STEP_TIMEOUT_SEC" -- tor_inactive
vekrona-dev sh vekrona-caffeine for "$CAFFEINE_SPAN" >/dev/null
vekrona-dev move 600 500
clear_notifications

# A first start: the launcher has neither Tor Browser nor the settings that it writes itself.
vekrona-dev run bash -c 'rm -rf "$HOME/.var/app/$1/data/torbrowser" "$HOME/.var/app/$1/config/torbrowser/settings.json"' _ "$TOR_BROWSER_APP"

started_at="$(vekrona-dev run date +%s)"
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type 'Tor Browser'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tor_browser_selected || { launcher_state; die "the launcher must select Tor Browser, so its desktop entry must be in the launcher's list"; }
vekrona-dev key ret
vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- tor_browser_running || die "the desktop entry must start the sandbox of Tor Browser, and no scope of it started"
log "ok: the desktop entry starts the sandbox of Tor Browser"

vekrona-dev until --timeout "$DOWNLOAD_TIMEOUT_SEC" -- browser_window_or_stopped || die "the download and the start of Tor Browser must end within $DOWNLOAD_TIMEOUT_SEC s"
browser_window_open || die "the launcher ended before the window of Tor Browser appeared"
no_qthread_abort
log "ok: the launcher downloads Tor Browser and starts it"

interfaces="$(sandbox_interfaces)"
[[ "$interfaces" == lo ]] || die "the Tor Browser sandbox must have lo and nothing else, but it has: $(tr '\n' ' ' <<<"$interfaces")"
log "ok: the sandbox has only lo"

vekrona-dev until --timeout "$TOR_UP_TIMEOUT_SEC" -- sandbox_reaches_tor || die "the sandbox must reach check.torproject.org through the tor socket, and the answer must say IsTor; last attempt: $(sandbox_socks_check 2>&1 | tail -n 3 || true)"
log "ok: check.torproject.org says the sandbox is on tor"

close_browser_window
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- browser_stopped || die "closing Tor Browser must end its sandbox, which ends when the launcher has ended"
vekrona-dev until --timeout "$TOR_STEP_TIMEOUT_SEC" -- tor_inactive || die "tor must stop when the last Tor Browser has closed"
# Tor stops only after `run` has ended the sandbox, so no scope of Tor Browser may be active by then.
tor_browser_stopped || die "no scope of Tor Browser may be active once tor has stopped, but these are: $(tor_browser_scopes | tr '\n' ' ')"
log "ok: tor stops when Tor Browser has closed, and no scope of it is active"

no_qthread_abort
# The desktop entry starts as a systemd-run unit (Exec.detached), whose stdout the journal keeps.
[[ "$(journal_count_since "$started_at" 'Downloading over Tor')" -ge 1 ]] || die "the launcher must download over tor, as its settings say"
log "ok: the launcher downloaded over tor"
