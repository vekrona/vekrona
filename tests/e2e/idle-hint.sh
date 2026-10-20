#!/usr/bin/env bash
set -euo pipefail

# swayidle sets the logind idle hint on the sway session, also when a text or ssh login came before it: a service of
# the user manager has no session of its own, so swayidle's own `idlehint` goes to the user's Display session, which
# logind refuses it; vekrona-idlehint names the sway session. The ssh session vekrona-dev works through is such a login. The idle hint is shortened to
# IDLEHINT_SEC with a drop-in.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
IDLEHINT_SEC=5

sway_session() {
  vekrona-dev run bash -c 'for id in $(loginctl show-user "$(id -u)" -p Sessions --value); do
    if [[ "$(loginctl show-session "$id" -p Type --value)" == wayland ]]; then echo "$id"; fi
  done'
}
idle_hint_is() { [[ "$(vekrona-dev run loginctl show-session "$SWAY_SESSION" -p IdleHint --value)" == "$1" ]]; }
unit_active() { [[ "$(vekrona-dev sh systemctl --user is-active vekrona-idle.service)" == active ]]; }
export -f idle_hint_is unit_active

vekrona-dev session
SWAY_SESSION="$(sway_session)"
[[ "$SWAY_SESSION" =~ ^[0-9a-z]+$ ]] || die "expected exactly one wayland session, got: $SWAY_SESSION"
export SWAY_SESSION

trap restore_idlehint EXIT
shorten_idlehint "$IDLEHINT_SEC"
vekrona-dev sh systemctl --user daemon-reload
vekrona-dev sh systemctl --user restart vekrona-idle.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- unit_active

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- idle_hint_is yes
log "ok: swayidle sets the idle hint on the sway session $SWAY_SESSION after ${IDLEHINT_SEC}s without input"

vekrona-dev key shift
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- idle_hint_is no
log "ok: input clears the idle hint"
