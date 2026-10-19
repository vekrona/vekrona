#!/usr/bin/env bash
set -euo pipefail

# The shared Popout (config/quickshell-shared/Vekrona/Popout.qml), hosted by a probe config that an IPC call grows and shrinks,
# opens and closes, and focuses a text field in.
# 1. A popout window follows the size of its content only after a round trip to the compositor. Until then the content must stay
#    where it is: the keep-awake popout jumped down and back when a "Wait for ..." list collapsed. The probe records every
#    position the content took inside the window.
# 2. A reopened popout does not resume on the field that held the focus when it closed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
GUEST_PROBE=/mnt/vekrona/tests/e2e/popout-probe
SHORT_CONTENT_PX=200
TALL_CONTENT_PX=700
POPOUT_PADDING_PX=$((2 * $(vekrona_token_get spacing space-4)))
SHORT_WINDOW_PX=$((SHORT_CONTENT_PX + POPOUT_PADDING_PX))
TALL_WINDOW_PX=$((TALL_CONTENT_PX + POPOUT_PADDING_PX))

probe() { vekrona-dev sh qs -p "$GUEST_PROBE" ipc call popout "$@"; }
window_height() { local report; report="$(probe report)" && echo "${report%% *}"; }
window_is() { [[ "$(window_height)" == "$1" ]]; }
export -f probe window_height window_is
export GUEST_PROBE

# Resizes the content, waits for the window to follow, and fails when the content sat anywhere but one place meanwhile.
resize_keeps_content_put() {
  local tall="$1" window_px="$2" direction="$3" report positions
  probe forget
  probe setTall "$tall"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_is "$window_px"
  report="$(probe report)"
  positions="${report#* }"
  [[ "$positions" != *" "* ]] || die "the content moved inside the popout while it $direction; positions in order: $positions"
  log "ok: the content stays at $positions while the popout $direction"
}

cleanup() { kill_guest -f "qs -p $GUEST_PROBE"; }

vekrona-dev session
trap cleanup EXIT
vekrona-dev spawn /tmp/vekrona-e2e-popout-probe.log -- qs -p "$GUEST_PROBE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_is "$SHORT_WINDOW_PX"

resize_keeps_content_put true "$TALL_WINDOW_PX" grows
resize_keeps_content_put false "$SHORT_WINDOW_PX" shrinks

probe focusField
[[ "$(probe fieldFocused)" == true ]] || die "the probe's text field must take the focus when asked to"
probe setOpen false
probe setOpen true
[[ "$(probe fieldFocused)" == false ]] || die "the popout resumed on the text field that held the focus when it closed"
log "ok: a reopened popout does not resume on the field that was focused"
