#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
INK="$(vekrona_token_get color ink dark)"
BAR="$(vekrona_token_get color surface-1 dark)"
INK_TRAY="$ROOT/tests/e2e/tray-ink.py"
GUEST_SNI=/tmp/bar-tray-fake-sni.py
GUEST_LOG=/tmp/bar-tray-fake-sni.log
TRAY_UNIT=tailscale-systray.service

# pkill exits 1 when no fake icon is running, which is fine.
stop_fake_icons() { vekrona-dev run pkill -f "[b]ar-tray-fake-sni.py" || [[ $? -eq 1 ]]; }
start_tray_unit() { vekrona-dev sh systemctl --user start "$TRAY_UNIT"; }

check_icon() {
  local kind="$1" shape="$2"
  vekrona-dev spawn "$GUEST_LOG" -- python3 "$GUEST_SNI" "$kind"
  registered() { vekrona-dev run grep -q registered "$GUEST_LOG"; }
  tray_ink_ok() { python3 "$INK_TRAY" "$without_icon" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$INK" "$BAR" "$shape" >/dev/null 2>&1; }
  export -f registered tray_ink_ok
  export GUEST_LOG INK_TRAY without_icon BAR_HEIGHT_PX INK BAR shape
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- registered
  if ! vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- tray_ink_ok; then
    log "the $kind tray icon did not settle within ${STEP_TIMEOUT_SEC}s; measuring the final state"
  fi
  python3 "$INK_TRAY" "$without_icon" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$INK" "$BAR" "$shape" || die "the $kind tray icon is drawn wrongly, see the measurement above"
  stop_fake_icons
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
trap stop_fake_icons EXIT
# The fake icon must be the only one in the tray, or the measured box would depend on the order of the icons.
if vekrona-dev sh systemctl --user is-active --quiet "$TRAY_UNIT"; then
  trap 'stop_fake_icons; start_tray_unit' EXIT
  vekrona-dev sh systemctl --user stop "$TRAY_UNIT"
fi
vekrona-dev run bash -c 'cat >"$1"' _ "$GUEST_SNI" <"$ROOT/tests/e2e/fake-sni.py"

without_icon="$(vekrona-dev shot)"

check_icon opaque dots
log "ok: an opaque tray icon shows its dots as ink on the bar, not a solid ink square"
check_icon alpha disc
log "ok: a tray icon with transparency keeps its shape as an ink silhouette"
