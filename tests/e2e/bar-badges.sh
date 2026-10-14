#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# OCR cannot read the badge's dark text on its danger fill, so a badge is found by its fill and its number by the ink inside it.
DANGER_HEX="$(vekrona_token_get color danger dark)"
# The last row of the bar is its border-hair bottom line, which is not widget ink.
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
BADGES="$ROOT/tests/e2e/bar-badges.py"
BADGE_COUNT=2
FEW=3
MANY=10
MIN_NUMBER_PIXELS=8

badge_measurement() { python3 "$BADGES" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$DANGER_HEX" "$BADGE_COUNT" "$MIN_NUMBER_PIXELS"; }
badges_alike() { badge_measurement >/dev/null; }
# The ink pixels of the bell's badge, the second one on the bar.
bell_ink() { badge_measurement | sed -n '2s/.*, \([0-9]*\) number pixels/\1/p'; }
bell_drawn_differently() { badges_alike && [[ "$(bell_ink)" != "$BELL_INK_BEFORE" ]]; }
export -f badge_measurement badges_alike bell_ink bell_drawn_differently
export BADGES BAR_HEIGHT_PX DANGER_HEX BADGE_COUNT MIN_NUMBER_PIXELS

restart_shell() { vekrona-dev sh systemctl --user restart vekrona-shell.service; }
trap unread_restore EXIT

vekrona-dev session
vekrona-dev move 600 500
unread_stash
unread_set 0
restart_shell
clear_notifications
edge_without_badges="$(settled_bar_left_edge)"
log "ok: with nothing unread the right side of the bar starts at x=$edge_without_badges"

notify() { vekrona-dev sh notify-send -p "Badge test $1" "body $1"; }
for i in $(seq "$FEW"); do
  id="$(notify "$i")"
  [[ "$i" == 2 ]] && DISMISSED_ID="$id"
done
unread_set "$FEW"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- badges_alike || log "the badges did not settle within ${STEP_TIMEOUT_SEC}s; measuring the final state"
badge_measurement || die "the agent and the notification bell must show the same badge with a number, see the measurement above"
log "ok: the agent and the notification bell show the same badge for $FEW: a red box with a number"

BELL_INK_BEFORE="$(bell_ink)"
export BELL_INK_BEFORE
vekrona-dev sh busctl --user call org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications CloseNotification u "$DISMISSED_ID" >/dev/null
unread_set "$((FEW - 1))"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bell_drawn_differently || { badge_measurement || true; die "the bell must count down to $((FEW - 1)) like the agent badge once a notification is dismissed"; }
log "ok: dismissing a notification lowers the bell's count to $((FEW - 1))"

BELL_INK_BEFORE="$(bell_ink)"
export BELL_INK_BEFORE
for i in $(seq "$((MANY - FEW + 1))"); do
  notify "more $i" >/dev/null
done
unread_set "$MANY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bell_drawn_differently || { badge_measurement || true; die "the bell must grow to $MANY like the agent badge"; }
edge_with_badges="$(bar_left_edge)"
[[ "$edge_with_badges" == "$edge_without_badges" ]] || die "the badges shifted the bar: its right side started at x=$edge_without_badges with nothing unread and x=$edge_with_badges with $MANY unread"
log "ok: the bar does not move when the badges appear and grow to $MANY"
