# Every shell test sources this instead of lib/common.sh. die() reports through the system journal, where the
# user's vekrona-errors watcher turns each record into a real entry in the error store, so a test's expected
# failures would land there. The reporter is therefore replaced for this test and for every process it starts.
export VEKRONA_ERROR_REPORTER=/usr/bin/true
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# `vekrona-error report` writes to the journal socket, which feeds the user's real error store. A missing path makes
# any report from a test fail loudly instead.
export VEKRONA_JOURNAL_SOCKET=/nonexistent/vekrona-test-journal-socket

clear_notifications() { vekrona-dev sh qs -c vekrona-shell ipc call notifications clearAll >/dev/null; }

SCREEN_COLORS="$VEKRONA_ROOT/tests/e2e/screen_colors.py"
export SCREEN_COLORS
panel_shown() { [[ "$(python3 "$SCREEN_COLORS" center "$(vekrona-dev shot)")" == "$PANEL_HEX" ]]; }
panel_hidden() { ! panel_shown; }
export -f panel_shown panel_hidden
