#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
INSTALL_MARKER=/run/vekrona-e2e-update-now
NOW_DROPIN_DIR=/run/systemd/system/vekrona-update-now.service.d
NIGHT_TIMER=vekrona-update-night.timer

shown() { vekrona-dev see text "$1"; }
install_marked() { vekrona-dev run test -e "$INSTALL_MARKER"; }
notify_finished() { [[ "$(vekrona-dev sh systemctl --user is-active vekrona-update-notify.service || true)" != activating ]]; }
night_timer_stopped() { [[ "$(vekrona-dev run systemctl is-active "$NIGHT_TIMER" || true)" == inactive ]]; }
export -f shown install_marked notify_finished night_timer_stopped
export INSTALL_MARKER NIGHT_TIMER

cleanup() {
  updates_restore
  updates_forget
  vekrona-dev run sudo rm -rf "$NOW_DROPIN_DIR" "$INSTALL_MARKER" /var/lib/vekrona/update-skip
  vekrona-dev run sudo systemctl daemon-reload
  vekrona-dev run sudo systemctl stop "$NIGHT_TIMER"
  clear_notifications
}

vekrona-dev session
vekrona-dev move 100 500
# A toast from the guest's own update check would keep the notify service waiting and swallow the file change below.
vekrona-dev sh systemctl --user stop vekrona-update-notify.service
clear_notifications
updates_stash
trap cleanup EXIT
updates_forget

# The real vekrona-update-now.service would run dnf; the scenario only needs to see that the button starts it.
vekrona-dev run sudo install -d "$NOW_DROPIN_DIR"
vekrona-dev run sudo bash -c 'printf "[Service]\nExecStart=\nExecStart=/usr/bin/touch %s\n" "$1" >"$2/zz-e2e.conf"' _ "$INSTALL_MARKER" "$NOW_DROPIN_DIR"
vekrona-dev run sudo systemctl daemon-reload

updates_write "$(updates_pending_json 2.1.3)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'updates are ready'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'claude-code'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Not tonight'
shown 'Install now' || die "the update toast must offer Install now"
log "ok: a new update check pops up a toast with both buttons"

vekrona-dev click-text '^Install$'
vekrona-dev move 100 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- install_marked
log "ok: Install now starts vekrona-update-now.service without a password"

clear_notifications
# The service must be done with the first toast to see the next change; and the content must be new, because the
# first toast is already remembered.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- notify_finished
updates_write "$(updates_pending_json 2.1.4)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shown 'Not tonight'
vekrona-dev run sudo systemctl start "$NIGHT_TIMER"
[[ "$(vekrona-dev run systemctl is-active "$NIGHT_TIMER")" == active ]] || die "the scenario could not arm $NIGHT_TIMER"
vekrona-dev click-text '^tonight$'
vekrona-dev move 100 500
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- night_timer_stopped
log "ok: Not tonight starts vekrona-update-skip.service, which stops the night timer"
