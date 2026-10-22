#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-widget.sh"

STEP_TIMEOUT_SEC=60
MISSING_BINARY=vekrona-no-such-binary
MISSING_ENTRY=VekronaMissingBinary
QUICK_ENTRY=VekronaQuickExit
APPLICATIONS_DIR='$HOME/.local/share/applications'

errors_after() { local now; now="$(shell_errors)" || abort "cannot count the shell errors"; ((now > ERRORS_BEFORE)); }
# The performance pill opens btop in a window of its own class (Perf.qml, monitorClass).
btop_open() { window_open vekrona.perf; }
perf_position() { bar_widget center load >"$POSITION_FILE"; }
quick_entry_ran() { vekrona-dev sh test -e "$QUICK_MARKER"; }
close_terminals() { vekrona-dev sh pkill -x ghostty || [[ $? -eq 1 ]]; }
cleanup() {
  close_terminals
  vekrona-dev sh bash -c "rm -f $APPLICATIONS_DIR/$MISSING_ENTRY.desktop $APPLICATIONS_DIR/$QUICK_ENTRY.desktop \"\$1\"" _ "$QUICK_MARKER"
  rm -f "$POSITION_FILE"
}
add_entry() {
  vekrona-dev sh bash -c "mkdir -p $APPLICATIONS_DIR && printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' \"\$1\" \"\$2\" >$APPLICATIONS_DIR/\$1.desktop" _ "$1" "$2"
}
launch() {
  vekrona-dev key super-spc
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
  vekrona-dev type "$1"
  entry_listed() { text_shown "$1"; }
  export -f entry_listed
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- entry_listed "$1"
  vekrona-dev key ret
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_hidden
}
export -f btop_open perf_position quick_entry_ran errors_after

POSITION_FILE="$(mktemp)"
QUICK_MARKER=/tmp/vekrona-quick-entry-ran
export POSITION_FILE QUICK_MARKER

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
trap cleanup EXIT
close_terminals

# The terminal is a long-lived instance, as on a real desktop, when the next launch is another window of the same app.
vekrona-dev spawn /tmp/launcher-errors-terminal.log -- ghostty --gtk-single-instance=true
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev sh bash -c "swaymsg -t get_tree | jq -e '[.. | objects | select((.app_id? // \"\") | test(\"ghostty\"))] | length > 0' >/dev/null"
ERRORS_BEFORE="$(shell_errors)"
export ERRORS_BEFORE

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- perf_position
read -r x y <"$POSITION_FILE"
vekrona-dev click "$x" "$y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- btop_open
! errors_after || die "launching btop from the performance pill logged a shell error"
log "ok: clicking a performance pill opens btop, without an error, while a terminal is already running"

add_entry "$QUICK_ENTRY" "touch $QUICK_MARKER"
launch "$QUICK_ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- quick_entry_ran
! errors_after || die "a launcher that exits at once is not a failure, but the shell logged an error"
log "ok: a launched command that exits at once is not reported as an error"

add_entry "$MISSING_ENTRY" "$MISSING_BINARY"
launch "$MISSING_ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- errors_after
shell_log="$(vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-shell)"
[[ "$shell_log" == *"$MISSING_BINARY"* ]] || die "the logged error must name the missing binary $MISSING_BINARY"
log "ok: launching a missing binary logs an error naming it"
