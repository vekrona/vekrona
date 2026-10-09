#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
# The last row of the bar is its border-hair bottom line, which is not widget ink.
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
# Two widgets sit two BarPill paddings (2 * space-2) apart, plus the padding of the 24-unit pictogram grid on both facing sides:
# 4 of 24 units each (the bell is the narrowest glyph), at size-icon-s px.
ICON_S_PX="$(vekrona_token_get size size-icon-s)"
GLYPH_BEARING_PX=$(((ICON_S_PX * 4 + 23) / 24))
GROUP_JOIN_PX="$(vekrona_token_get spacing space-2)"
MAX_GAP_PX=$((2 * GROUP_JOIN_PX + 2 * GLYPH_BEARING_PX))
MAX_GAP_SPREAD_PX=6
GAPS="$ROOT/tests/e2e/bar-gaps.py"
SEPARATOR="$ROOT/tests/e2e/bar-separator.py"
SEPARATOR_MIN_HEIGHT_PX=$((BAR_HEIGHT_PX / 2))
# The separator is drawn in the line token on the surface-1 bar.
# Antialiasing and fractional scale blend the line with the surface at the edges, so require half the token difference.
SEPARATOR_TOKEN_CONTRAST="$(python3 "$ROOT/tests/e2e/screen_colors.py" contrast "$(vekrona_token_get color line dark)" "$(vekrona_token_get color surface-1 dark)")"
SEPARATOR_MIN_CONTRAST=$((SEPARATOR_TOKEN_CONTRAST / 2))

bar_spacing_ok() {
  python3 "$GAPS" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$GROUP_JOIN_PX" "$MAX_GAP_PX" "$MAX_GAP_SPREAD_PX" "$ICON_S_PX" >/dev/null
}
export -f bar_spacing_ok
export ROOT BAR_HEIGHT_PX GROUP_JOIN_PX MAX_GAP_PX MAX_GAP_SPREAD_PX ICON_S_PX GAPS

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
# Widgets load at their own pace: wait for the spacing to settle.
if ! vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_spacing_ok; then
  log "the bar spacing did not settle within ${STEP_TIMEOUT_SEC}s; measuring the final state"
fi

python3 "$GAPS" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$GROUP_JOIN_PX" "$MAX_GAP_PX" "$MAX_GAP_SPREAD_PX" "$ICON_S_PX" || die "the right-side bar widgets must be evenly spaced at most $MAX_GAP_PX px apart, see the measurement above"
log "ok: every right-side bar widget is separated by a similar, tight gap"

python3 "$SEPARATOR" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$SEPARATOR_MIN_HEIGHT_PX" "$SEPARATOR_MIN_CONTRAST" || die "the bar must show a visible separator line after the workspaces, see the measurement above"
log "ok: the separator after the workspaces is clearly visible"
