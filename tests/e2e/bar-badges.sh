#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-widget.sh"
source "$ROOT/tests/e2e/lib/bar-dot.sh"

STEP_TIMEOUT_SEC=60
# An unread dot is found by its danger fill.
DANGER_HEX="$(vekrona_token_get color danger dark)"
# An icon-only pill is its icon between two paddings. A dot hangs over that padding and adds nothing.
PILL_PX=$(($(vekrona_token_get size size-icon-s) + 2 * $(vekrona_token_get spacing space-2)))
# A hovered pill paints this behind its icon. Its row is the pill's second one, above the dot and the pointer, which the
# screenshot draws from the pointer's tip down.
HOVER_HEX="$(vekrona_token_get color surface-2 dark)"
PILL_ROW=$((($(vekrona_token_get size size-bar) - $(vekrona_token_get size size-target)) / 2 + 1))
PILL_WIDTH="$ROOT/tests/e2e/bar-pill-width.py"
# Where the pointer rests: over no widget.
PARK_X=600
PARK_Y=500
BADGES="$ROOT/tests/e2e/bar-badges.py"
FEW=3

dots() { python3 "$BADGES" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$DANGER_HEX" "$1"; }
dots_shown() { dots "$1" >/dev/null; }
export -f dots dots_shown
# The width of the pill of the named bar widget, found by resting the pointer on it. The pointer enters from the empty
# desktop each time: a pill under a pointer that was on another pill a moment ago does not always light up.
pill_width() {
  local x y
  read -r x y <<<"$(bar_widget center "$1")"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- hovered_pill_width "$x" "$y" >/dev/null || die "no pill lit up under the pointer on the $1 icon at x=$x"
  hovered_pill_width "$x" "$y"
}
hovered_pill_width() {
  vekrona-dev move "$PARK_X" "$PARK_Y"
  vekrona-dev move "$1" "$2"
  python3 "$PILL_WIDTH" "$(vekrona-dev shot)" "$PILL_ROW" "$1" "$HOVER_HEX"
}
export -f hovered_pill_width
export BADGES DANGER_HEX PILL_ROW PILL_WIDTH HOVER_HEX PARK_X PARK_Y

assert_icon_pills_are_alike() {
  local name width
  for name in agent bell; do
    width="$(pill_width "$name")"
    [[ "$width" == "$PILL_PX" ]] || die "the $name pill is $width px wide $1, not its icon between two paddings ($PILL_PX px)"
  done
  log "ok: the agent and the bell pills are $PILL_PX px wide $1"
}

trap 'run_cleanups unread_restore "rm -f \"\$DOT_STATES\""' EXIT

vekrona-dev session
vekrona-dev move "$PARK_X" "$PARK_Y"
unread_stash
restart_shell
unread_set 0
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- errors_state_is '.loaded and .unread == 0' || die "the shell must read the unread count 0: $(errors_state)"
clear_notifications
edge_without_dots="$(settled_bar_left_edge)"
dots 0 || die "with nothing unread the bar must show no dot"
log "ok: with nothing unread the bar shows no dot and its right side starts at x=$edge_without_dots"
assert_icon_pills_are_alike "with nothing unread"
vekrona-dev move "$PARK_X" "$PARK_Y"

for i in $(seq "$FEW"); do
  vekrona-dev sh notify-send "Dot test $i" "body $i"
done
# The agent's dot pulses when its count rises and then stays solid. The bell has no pulse yet.
read -r agent_x agent_y <<<"$(bar_widget center agent)"
dot_place "$agent_x" "$agent_y"
unread_set "$FEW"
runs="$(dot_dim_runs "$FEW")"
((runs >= 1)) || die "the agent's dot must pulse when the unread count rises from 0 to $FEW, but it never dimmed"
log "ok: the agent's dot pulses ($runs dim stretches) when the count rises, then stays solid"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dots_shown 2 || { dots 2 || true; die "the agent and the notification bell must each show the same solid square dot"; }
log "ok: the agent and the notification bell show the same square dot for $FEW unread"

unread_set "$((FEW + 1))"
runs="$(dot_dim_runs "$((FEW + 1))")"
((runs >= 1)) || die "the agent's dot must pulse again when the unread count rises once more, but it never dimmed"
log "ok: a further rise pulses the dot again"

unread_set "$FEW"
runs="$(dot_dim_runs "$FEW")"
((runs == 0)) || die "the agent's dot must not pulse when the unread count falls, but it dimmed $runs times"
log "ok: a fall of the count does not pulse the dot"

edge_with_dots="$(bar_left_edge)"
[[ "$edge_with_dots" == "$edge_without_dots" ]] || die "the dots shifted the bar: its right side started at x=$edge_without_dots with nothing unread and x=$edge_with_dots with $FEW unread"
log "ok: the bar does not move when the dots appear"
assert_icon_pills_are_alike "with the dots shown"
vekrona-dev move "$PARK_X" "$PARK_Y"

unread_set 0
clear_notifications
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dots_shown 0 || { dots 0 || true; die "the dots must disappear once nothing is unread"; }
log "ok: the dots disappear once nothing is unread"
