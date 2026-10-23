# shellcheck shell=bash
# Sourced by scenarios that watch an unread dot pulse, after tests/lib.sh. dot_place CENTER_X CENTER_Y takes the centre
# of the pill's icon and picks the pixel inside its dot (the dot hangs on the icon's top right corner, bottom edge at
# the icon's centre). dot_dim_runs COUNT then reads that pixel back to back until the shell has settled on COUNT.
DOT_PX="$(vekrona_token_get spacing space-2)"
DOT_STATES="$(mktemp)"
export DOT_PX DOT_STATES

dot_place() {
  DOT_X=$(($1 + ICON_S_PX / 2 + DOT_PX / 2))
  DOT_Y=$(($2 - DOT_PX / 2 - 1))
  export DOT_X DOT_Y
}
# The robot is the only pill with a dot while no notification is unread. robot_dotted leaves the dot's bounds in DOT_FILE.
robot_dotted() { python3 "$VEKRONA_ROOT/tests/e2e/bar-badges.py" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$DANGER_HEX" 1 >"$DOT_FILE"; }
no_dot() { python3 "$VEKRONA_ROOT/tests/e2e/bar-badges.py" "$(vekrona-dev shot)" "$BAR_HEIGHT_PX" "$DANGER_HEX" 0 >/dev/null; }
# solid, dim (part way between solid and gone) or absent, on a fresh screenshot.
dot_state() { python3 "$VEKRONA_ROOT/tests/e2e/bar-dot-state.py" "$(vekrona-dev shot)" "$DANGER_HEX" "$DOT_X" "$DOT_Y" "$DOT_PX"; }
dot_is() { [[ "$(dot_state)" == "$1" ]]; }
# The robot's dot as the shell reports it: {loaded, unread, pulsing}. A pulse starts in the same step that takes in the new count,
# so a state with the count and no pulse is a pulse that is over, or one that never was.
errors_state() { vekrona-dev sh qs -c vekrona-shell ipc call errors state; }
errors_state_is() { errors_state | jq -e "$1" >/dev/null; }
# Records one more sample of the dot, and succeeds when the shell has taken in the count $1 and is not pulsing.
dot_sampled_settled() {
  dot_state >>"$DOT_STATES"
  errors_state_is ".unread == $1 and (.pulsing | not)"
}
export -f robot_dotted no_dot dot_state dot_is errors_state errors_state_is dot_sampled_settled
# Reads the dot back to back until the shell says it has settled on the unread count $1 and is not pulsing, then reads it once
# more, which must be solid. Prints in how many separate stretches it was dim on the way.
dot_dim_runs() {
  : >"$DOT_STATES"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- dot_sampled_settled "$1" || { tr '\n' ' ' <"$DOT_STATES" >&2; die "the shell never settled on $1 unread with the dot not pulsing: $(errors_state)"; }
  dot_state >>"$DOT_STATES"
  [[ "$(tail -n 1 "$DOT_STATES")" == solid ]] || { tr '\n' ' ' <"$DOT_STATES" >&2; die "the dot is not solid once its pulse is over"; }
  awk '$1 == "dim" && prev != "dim" { runs++ } { prev = $1 } END { print runs + 0 }' "$DOT_STATES"
}
