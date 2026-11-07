# shellcheck shell=bash
# Sourced by the Sync scenarios that click through the bar's Sync popout, after tests/lib.sh and lib/bar-widget.sh. Everything
# is real input: a pointer click on the pill and on the words of the popout (found by OCR), key presses into its text field, and
# the same on the file chooser of the desktop portal. POPOUT_SHOTS_DIR (words.sh) collects screenshots.

# shellcheck source=words.sh
source "$(dirname "${BASH_SOURCE[0]}")/words.sh"

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
