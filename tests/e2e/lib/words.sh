# shellcheck shell=bash
# Sourced by the scenarios that click through a popout of the bar by the words it shows, after tests/lib.sh (so it lives in lib/, out of
# reach of a glob that runs every scenario). The scenario sets STEP_TIMEOUT_SEC.

# Whether a word of the screen matches the regex $1, which is read against one word at a time.
word_shown() { vekrona-dev see find "$1" >/dev/null; }
export -f word_shown
# The pointer rests here after a click on a word of the popout: on the word, its arrow breaks the OCR of the text that the click
# changes ("Copied", "Pair request sent"), and a rest away from the bar and the popout is where no hover shows.
POINTER_REST_X=640
POINTER_REST_Y=400
# Clicks the first word of the screen that matches the regex $1, once it is there, or with --last the last one (a button whose
# label is also the first word of the text above it: "Pair with it?", then Pair).
click_word() {
  local found last=()
  if [[ "$1" == --last ]]; then
    last=(--last)
    shift
  fi
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- word_shown "$1"
  found="$(vekrona-dev see find "${last[@]}" "$1")" || die "the word /$1/ was on screen and is gone"
  # shellcheck disable=SC2086
  vekrona-dev click $found
  vekrona-dev move "$POINTER_REST_X" "$POINTER_REST_Y"
}
# Saves a screenshot of the state $1 a scenario reached, as $POPOUT_SHOTS_DIR/$1.png, when that directory is set (a person reads the
# pictures; the scenario does not).
snap() {
  [[ -z "${POPOUT_SHOTS_DIR:-}" ]] || vekrona-dev shot "$POPOUT_SHOTS_DIR/$1.png" >/dev/null
}
export -f snap
