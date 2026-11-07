#!/usr/bin/env bash
# Bazaar, the store for software the user installs on their own, is installed system-wide, opens from the launcher, and leaves
# no process behind once its window is closed (it runs no background update unless the user turns on its opt-in auto-update).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
# Bazaar's daemon ends a few seconds after its last window closes; this is generous for a loaded VM.
EXIT_TIMEOUT_SEC=30
APP=io.github.kolunmi.Bazaar

system_has_bazaar() {
  local apps
  apps="$(vekrona-dev run flatpak list --system --app --columns=application)" || abort "cannot list the system flatpak apps"
  grep -qx "$APP" <<<"$apps"
}
bazaar_window_open() { window_open "$APP"; }
bazaar_stopped() { flatpak_stopped "$APP"; }
# The launcher's selected row is Bazaar's application row (the typed query on the screen would match as well, so not OCR).
bazaar_selected() { launcher_is ".selectedId | startswith(\"apps:$APP\")"; }
export -f bazaar_window_open bazaar_stopped bazaar_selected
export APP

stop_bazaar() {
  bazaar_stopped || vekrona-dev run flatpak kill "$APP"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bazaar_stopped
}

# Both cleanups run whatever the first one does, and the scenario still ends with the status it had, or 1 if a cleanup failed.
cleanup() {
  local status=$?
  stop_bazaar || status=1
  close_launcher || status=1
  exit "$status"
}

vekrona-dev session
trap cleanup EXIT
stop_bazaar
vekrona-dev move 600 500
clear_notifications

system_has_bazaar || die "Bazaar must be installed system-wide ($APP in flatpak list --system), but it is not"
log "ok: Bazaar is installed system-wide"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type Bazaar
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bazaar_selected || { launcher_state; die "the launcher must select Bazaar, so Flatpak exports must be in the shell's XDG_DATA_DIRS"; }
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bazaar_window_open || die "Bazaar must open from the launcher"
log "ok: Bazaar opens from the launcher"

vekrona-dev sh swaymsg "[app_id=$APP] kill" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_closed "$APP" || die "Bazaar's window must close"
vekrona-dev until --timeout "$EXIT_TIMEOUT_SEC" -- bazaar_stopped || die "Bazaar must not keep running in the background after its window closed (flatpak ps still lists $APP)"
log "ok: Bazaar ends with its window"
