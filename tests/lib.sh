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

# How many failed commands the shell has logged: the lines the error pipeline turns into entries in the error store.
shell_errors() { vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-shell | grep -cE 'ERROR.*qml.* exited [0-9]+: ' || [[ $? -eq 1 ]]; }
export -f shell_errors

# The root-side update check owns /var/lib/vekrona/updates.json. A scenario sets its own content and puts the
# original back on exit with updates_restore; the user-side "already told" memory is cleared with updates_forget.
UPDATES_JSON=/var/lib/vekrona/updates.json
UPDATES_STASH=/var/lib/vekrona/updates.json.e2e-stash
updates_stash() { vekrona-dev run sudo bash -c 'if [[ -e "$1" ]]; then cp -p "$1" "$2"; else rm -f "$2"; fi' _ "$UPDATES_JSON" "$UPDATES_STASH"; }
# Replaced by rename, like the root writer does, so a watcher sees what it sees in production.
updates_write() { vekrona-dev run sudo bash -c 'install -d /var/lib/vekrona && printf "%s\n" "$1" >"$2.tmp" && chmod 644 "$2.tmp" && mv "$2.tmp" "$2"' _ "$1" "$UPDATES_JSON"; }
updates_restore() { vekrona-dev run sudo bash -c 'if [[ -e "$2" ]]; then mv "$2" "$1"; else rm -f "$1"; fi' _ "$UPDATES_JSON" "$UPDATES_STASH"; }
updates_forget() { vekrona-dev run bash -c 'rm -f "$HOME/.local/state/vekrona/update-notified"'; }
# A check result with pending updates; $1 is the version the agent updates to.
updates_pending_json() {
  printf '{"checked":"2026-10-09T09:00:03+02:00","pending":true,"night_armed":true,"groups":[{"name":"Agents","items":[{"name":"claude-code","from":"2.1.0","to":"%s"}]}]}' "$1"
}
