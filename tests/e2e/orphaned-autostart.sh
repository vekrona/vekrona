#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
INSTALL_TIMEOUT_SEC=900
BLUEMAN_UNIT=app-blueman@autostart.service
NM_UNIT='app-nm\x2dapplet@autostart.service'

# Anchored, because the guest shell that runs pgrep carries this text in its own command line.
blueman_applet_running() { vekrona-dev sh pgrep -f '^/usr/bin/python3 .*/usr/bin/blueman-applet$' >/dev/null; }
nm_applet_running() { vekrona-dev sh pgrep -x nm-applet >/dev/null; }
blueman_applet_gone() { absent blueman_applet_running; }
nm_applet_gone() { absent nm_applet_running; }
package_installed() { vekrona-dev run rpm -q "$1" >/dev/null; }
unit_orphaned() { vekrona-dev sh bash -c 'systemctl --user list-units --all --plain --no-legend "$1" | grep -q "not-found active running"' _ "$1"; }
# is-active exits 3 for a unit that is inactive or failed and 4 once the user manager has dropped it, which is the same for us.
unit_inactive() {
  local status=0
  vekrona-dev sh bash -c 'systemctl --user is-active --quiet "$1"' _ "$1" || status=$?
  case "$status" in
    0) return 1 ;;
    3 | 4) return 0 ;;
    *) abort "cannot tell whether $1 is active, 'systemctl is-active' exited $status" ;;
  esac
}
export -f blueman_applet_running nm_applet_running blueman_applet_gone nm_applet_gone package_installed unit_orphaned unit_inactive

install_log="$(mktemp)"
trap 'rm -f "$install_log"' EXIT

# start_applet PACKAGE UNIT RUNNING: installs PACKAGE and starts its applet from its autostart entry as sway does at login (systemd's
# generator turns the entry into UNIT).
start_applet() {
  local package="$1" unit="$2" running="$3"
  vekrona-dev run sudo dnf -y install "$package" >/dev/null
  vekrona-dev sh bash -c 'systemctl --user daemon-reload && systemctl --user start "$1"' _ "$unit"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- "$running" || die "$package's applet did not start from its autostart entry, so the scenario would not reproduce an orphan"
  log "ok: $package's applet runs from its autostart entry"
}

# stages_kill_applet PACKAGE UNIT GONE: runs stages 30 and 70, which must leave PACKAGE removed, kill the applet, leave UNIT
# inactive and check that no orphan runs.
stages_kill_applet() {
  local package="$1" unit="$2" gone="$3"
  vekrona-dev sh timeout "$INSTALL_TIMEOUT_SEC" bash -c 'cd "$HOME/$1" && ./install.sh 30-packages 70-verify' _ "$GUEST_CHECKOUT_SUBPATH" >"$install_log" 2>&1 \
    || die "stages 30 and 70 failed with $package's applet running:
$(tail -n 40 "$install_log")"
  log "ok: stages 30 and 70 passed with $package's applet running"

  absent package_installed "$package" || die "stage 30 left $package installed"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- "$gone" || die "stage 30 ran but $package's orphaned applet still runs"
  log "ok: stage 30 killed $package's orphaned applet"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unit_inactive "$unit" || die "stage 30 killed $package's applet but $unit is still active"
  log "ok: $unit is no longer active"
  grep -q 'ok: no XDG autostart app runs without its desktop entry' "$install_log" || die "stage 70 did not check for orphaned autostart apps:
$(tail -n 40 "$install_log")"
  log "ok: stage 70 checked that no autostart app runs without its desktop entry"
}

vekrona-dev session

# The package goes away under the running applet, and the user manager re-executes, as the host's did before the stage ran. The
# guest's manager still stops the unit by name afterwards, which the host's refused ("not loaded"), so this case cannot reproduce
# that state: tests/stages/test-orphaned-autostart.sh specifies it with a refusing systemctl.
start_applet blueman "$BLUEMAN_UNIT" blueman_applet_running
vekrona-dev run sudo dnf -y remove blueman >/dev/null
vekrona-dev sh systemctl --user daemon-reexec
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unit_orphaned "$BLUEMAN_UNIT" || die "after the re-exec $BLUEMAN_UNIT is not listed as not-found active, so the scenario would not reproduce an orphan"
blueman_applet_running || die "the applet died with its package, so the scenario would not reproduce an orphan"
log "ok: blueman's applet runs on as an orphaned unit after the user manager re-executed"
stages_kill_applet blueman "$BLUEMAN_UNIT" blueman_applet_gone

# network-manager-applet ships no user unit, so removing it alone triggers no daemon-reload of the user manager (blueman's systemd
# user files did); only the reload stage 30 does itself makes the generated unit not-found.
start_applet network-manager-applet "$NM_UNIT" nm_applet_running
stages_kill_applet network-manager-applet "$NM_UNIT" nm_applet_gone
