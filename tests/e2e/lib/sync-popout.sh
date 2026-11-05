# shellcheck shell=bash
# Sourced by the Sync scenarios that click through the bar's Sync popout, after tests/lib.sh and lib/bar-widget.sh. Everything
# is real input: a pointer click on the pill and on the words of the popout (found by OCR), key presses into its text field, and
# the same on the file chooser of the desktop portal. SYNC_SHOTS_DIR, when set, collects a screenshot of each state a scenario
# calls snap for.

# A click on the pill toggles the popout (the first opens it, the second closes it).
click_sync_pill() {
  local x y
  read -r x y <<<"$(bar_widget center sync)"
  [[ -n "${x:-}" ]] || die "the bar must show the sync icon"
  vekrona-dev click "$x" "$y"
}
CHOOSER_LISTING_SEC=10
# The popout's last row, which is always there.
popout_open() { text_shown 'Share a folder'; }
export -f popout_open
# A device row under Nearby reads "Syncthing device ID7"; tesseract reads the small bold "Syncthing" as "Synething" for as long as the
# frame stays the same, so the row is found by the words after it.
nearby_row_shown() { text_shown 'thing device'; }
export -f nearby_row_shown
# Leaves the popout open. A popout that a step of the scenario left open (Accept does) stays as it is,
# because the click that opens a closed popout would close an open one.
open_popout() {
  if absent popout_open; then click_sync_pill; fi
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- popout_open
}
close_popout() { absent popout_open || click_sync_pill; }
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
snap() {
  [[ -z "${SYNC_SHOTS_DIR:-}" ]] || vekrona-dev shot "$SYNC_SHOTS_DIR/$1.png" >/dev/null
}
# Scenarios that look at the popout call it with a jq test of sync.json and the words the popout must show for it.
export -f snap

# The file chooser of the desktop portal ("Share a folder", "Send files"), which vekrona-sync opens after the popout closed.
chooser_open() {
  vekrona-dev sh bash -c 'swaymsg -t get_tree' | jq -e --arg title "$1" '[.. | objects | select(.name? == $title)] | length > 0' >/dev/null
}
export -f chooser_open
close_chooser() {
  if chooser_open 'Share a folder' || chooser_open 'Send files'; then
    vekrona-dev sh swaymsg '[app_id="xdg-desktop-portal-gtk"] kill' >/dev/null
  fi
}
# Picks the entry of the home directory whose name matches the word regex $1 in the chooser that is open, and confirms with the key $2 (the mnemonic of its
# button: Alt+S for Select, Alt+O for Open, which OCR cannot read on the button's accent color): Alt+Home (the Recent view, which opens first, lists "Home" in a column of its own, so the sidebar's word is no safe click), the entry's row, the key.
choose_in_home() {
  vekrona-dev key alt-home
  # A key that comes while the chooser is still being drawn is lost, and Home is the same however often it is pressed.
  vekrona-dev until --timeout "$CHOOSER_LISTING_SEC" -- word_shown "$1" || vekrona-dev key alt-home
  click_word "$1"
  snap chooser-picked
  vekrona-dev key "$2"
}
