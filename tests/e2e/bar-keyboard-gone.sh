#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
NEXT_LAYOUT_CHORD=super-ctrl-alt-space
PILL_DRIFT_PX=20
# Where the guest remembers which drivers it took the keyboards from, so that they can be given back.
UNBOUND_FILE=/tmp/e2e-keyboards-unbound

code_shown() {
  local center x
  center="$(vekrona-dev see find "$1")" || return 1
  x="${center%% *}"
  ((x > PILL_X - PILL_DRIFT_PX && x < PILL_X + PILL_DRIFT_PX))
}
code_hidden() { ! code_shown "$1"; }
export -f code_shown code_hidden
export PILL_DRIFT_PX UNBOUND_FILE

keyboards_listed() { vekrona-dev sh swaymsg -t get_inputs --raw | jq -r '.[] | select(.type == "keyboard") | .name'; }
no_keyboards() { [[ -z "$(keyboards_listed)" ]]; }
export -f keyboards_listed no_keyboards

# The VM's keyboard is not a USB device (QMP injects it), so it cannot be hot-unplugged. Unbinding its driver removes the
# input device the way a resume does: Sway drops it from get_inputs and emits an input event.
unplug_keyboards() {
  local name names
  mapfile -t names < <(keyboards_listed)
  for name in "${names[@]}"; do
    vekrona-dev run sudo bash -c '
for input in /sys/class/input/input*; do
  [[ "$(<"$input/name")" == "$1" ]] || continue
  parent="$(dirname "$(readlink -f "$input")")"
  [[ -e "$parent/driver" ]] || { echo "keyboard $1 has no driver to unbind" >&2; exit 1; }
  echo "$(readlink -f "$parent/driver") $(basename "$parent")" >>"$2"
  basename "$parent" >"$parent/driver/unbind"
done
' _ "$name" "$UNBOUND_FILE"
  done
}
plug_keyboards() {
  vekrona-dev run sudo bash -c '
[[ -e "$1" ]] || exit 0
while read -r driver device; do
  echo "$device" >"$driver/bind"
done <"$1"
rm -f "$1"
' _ "$UNBOUND_FILE"
}
keyboard_errors() { vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-shell | grep -c 'Keyboard:' || [[ $? -eq 1 ]]; }

vekrona-dev session
clear_notifications
vekrona-dev move 600 500

# Sway splits a command at commas, so the layout list is quoted inside the command.
set_layouts() { vekrona-dev sh swaymsg "input type:keyboard xkb_layout \"$1\""; }
restore() {
  plug_keyboards
  set_layouts us
}
trap restore EXIT
set_layouts us,ua

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev see text "EN"
read -r PILL_X y <<<"$(vekrona-dev see find "EN")"
[[ -n "${PILL_X:-}" && -n "${y:-}" ]] || die "the bar must show the layout code EN once the keymap has two layouts"
export PILL_X
log "ok: the bar shows EN for a us,ua keymap at x=$PILL_X"

errors_before="$(keyboard_errors)"
unplug_keyboards
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_keyboards
# The pill leaves EN only once the shell has read the empty list, so the input event is processed by then.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_hidden "EN"
[[ "$(keyboard_errors)" == "$errors_before" ]] || die "no keyboard at all is a normal state while the system resumes and must not log a Keyboard error"
log "ok: with every keyboard gone the shell logs no Keyboard error"

plug_keyboards
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "EN"
log "ok: the bar shows EN again once a keyboard is back"

vekrona-dev key "$NEXT_LAYOUT_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "UA"
log "ok: Hyper+Space switches to the next layout and the bar shows UA"
