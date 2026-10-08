#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
BAR_HEIGHT_PX="$(vekrona_token_get size size-bar)"
# One pixel of glyph side bearing on top of the bar's widget spacing.
MAX_GAP_PX=$(($(vekrona_token_get spacing space-2) + 1))
MAX_GAP_SPREAD_PX=6
# A percent label is bar text (type token "label") scaled by the shell font scale; its glyphs are at most one em tall,
# plus one pixel of antialiasing. Icons (size-icon-s and up) are taller, which is what tells them apart from labels.
LABEL_PX="$(jq -er '[.type.groups[].styles[] | select(.name == "label") | .fontSize][0] | sub("px$"; "")' "$ROOT/config/tokens.json")"
LABEL_MAX_HEIGHT_PX="$(awk -v px="$LABEL_PX" -v scale="$(vekrona_design_get dmsFontScale)" 'BEGIN { e = px * scale; c = int(e); if (c < e) c++; print c + 1 }')"
GAPS="$ROOT/tests/e2e/bar-gaps.py"
SEPARATOR="$ROOT/tests/e2e/bar-separator.py"
SEPARATOR_MIN_HEIGHT_PX=$((BAR_HEIGHT_PX / 2))
# The separator is drawn in the line token on the surface-1 bar.
# Antialiasing and fractional scale blend the line with the surface at the edges, so require half the token difference.
SEPARATOR_TOKEN_CONTRAST="$(python3 "$ROOT/tests/e2e/screen_colors.py" contrast "$(vekrona_token_get color line dark)" "$(vekrona_token_get color surface-1 dark)")"
SEPARATOR_MIN_CONTRAST=$((SEPARATOR_TOKEN_CONTRAST / 2))

bar_spacing_ok() {
  python3 "$GAPS" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$MAX_GAP_PX" "$MAX_GAP_SPREAD_PX" "$LABEL_MAX_HEIGHT_PX" >/dev/null
}
export -f bar_spacing_ok
export ROOT BAR_HEIGHT_PX MAX_GAP_PX MAX_GAP_SPREAD_PX LABEL_MAX_HEIGHT_PX GAPS

vekrona-dev session
vekrona-dev move 600 500
# Widgets load at their own pace: wait for the spacing to settle.
if ! vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- bar_spacing_ok; then
  log "the bar spacing did not settle within ${STEP_TIMEOUT_SEC}s; measuring the final state"
fi

python3 "$GAPS" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$MAX_GAP_PX" "$MAX_GAP_SPREAD_PX" "$LABEL_MAX_HEIGHT_PX" || die "the right-side bar pictograms must be evenly spaced at most $MAX_GAP_PX px apart, see the measurement above"
log "ok: every right-side bar pictogram is separated by a similar, tight gap"

python3 "$SEPARATOR" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$SEPARATOR_MIN_HEIGHT_PX" "$SEPARATOR_MIN_CONTRAST" || die "the bar must show a visible separator line after the workspaces, see the measurement above"
log "ok: the separator after the workspaces is clearly visible"
