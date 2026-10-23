# shellcheck shell=bash
# Sourced by scenarios that look at one widget of the bar, after tests/lib.sh (so it lives in lib/, out of reach of a
# glob that runs every scenario: run alone it has no vekrona_token_get). bar_widget COMMAND [NAME] prints what
# bar-widget.py says about the widget on a fresh screenshot, see there for the commands and the names.
BAR_WIDGET="$VEKRONA_ROOT/tests/e2e/bar-widget.py"
# The last row of the bar is its border-hair bottom line, which is not widget ink.
bar_px="$(vekrona_token_get size size-bar)"
border_hair_px="$(vekrona_token_get border border-hair)"
BAR_HEIGHT_PX=$((bar_px - border_hair_px))
ICON_S_PX="$(vekrona_token_get size size-icon-s)"
GROUP_JOIN_PX="$(vekrona_token_get spacing space-2)"
bar_widget() { python3 "$BAR_WIDGET" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$ICON_S_PX" "$GROUP_JOIN_PX" "$@"; }
export -f bar_widget
export BAR_WIDGET BAR_HEIGHT_PX ICON_S_PX GROUP_JOIN_PX
