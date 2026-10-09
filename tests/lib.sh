# Every shell test sources this instead of lib/common.sh. die() reports through the system journal, where the
# user's vekrona-errors watcher turns each record into a real entry in the error store, so a test's expected
# failures would land there. The reporter is therefore replaced for this test and for every process it starts.
export VEKRONA_ERROR_REPORTER=/usr/bin/true
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# `vekrona-error report` writes to the journal socket, which feeds the user's real error store. A missing path makes
# any report from a test fail loudly instead.
export VEKRONA_JOURNAL_SOCKET=/nonexistent/vekrona-test-journal-socket

# logind suspends only when every session that can idle is idle, and the ssh session vekrona-dev works through
# never is: it has no terminal to take an idle time from. Class "background" takes it out of that count and out of the
# candidates for the user's Display session, the one swayidle's idle hint lands on. pam_systemd reads the class from
# the PAM environment, so the scenario adds a pam_env line to sshd's PAM stack and replaces its own ssh session, which
# the next vekrona-dev call reconnects.
# vekrona-dev reads the lock state through its own ssh session, which matches the session the lock screen writes to
# (the Display session) only while the ssh session is the user's first. Restoring therefore also logs the sway session
# out and in again, so that the ssh session is the only one left when the next login starts.
SSH_SESSION_ENV=/etc/vekrona-e2e-ssh-session.env
ssh_session_class() { vekrona-dev run bash -c 'loginctl show-session "$XDG_SESSION_ID" -p Class --value' 2>/dev/null; }
ssh_session_is_background() { [[ "$(ssh_session_class)" == background ]]; }
ssh_session_is_user() { [[ "$(ssh_session_class)" == user ]]; }
sway_gone() { ! vekrona-dev run pgrep -x sway >/dev/null; }
# sway can die before it answers the command that ends it, so the status says nothing: sway_gone is the check.
logout_sway() {
  vekrona-dev sh swaymsg exit >/dev/null || true
  vekrona-dev until --timeout 60 -- sway_gone
}
export -f ssh_session_class ssh_session_is_background ssh_session_is_user sway_gone
replace_ssh_session() { vekrona-dev run bash -c 'sudo systemd-run --no-block loginctl terminate-session "$XDG_SESSION_ID"' >/dev/null; }
ssh_sessions_background() {
  vekrona-dev run sudo bash -c '
printf "XDG_SESSION_CLASS=background\n" >"$1"
grep -q "$1" /etc/pam.d/sshd || sed -i "/^session    include      password-auth/i session    required     pam_env.so envfile=$1" /etc/pam.d/sshd
' _ "$SSH_SESSION_ENV"
  ssh_session_is_background || replace_ssh_session
  vekrona-dev until --timeout 60 -- ssh_session_is_background
}
# The pam_env line goes first: with its file gone, a remaining line would refuse every ssh login.
ssh_sessions_restore() {
  vekrona-dev run sudo bash -c 'sed -i "\|$1|d" /etc/pam.d/sshd && rm -f "$1"' _ "$SSH_SESSION_ENV"
  ssh_session_is_user || replace_ssh_session
  vekrona-dev until --timeout 60 -- ssh_session_is_user
  logout_sway
  vekrona-dev session
}

clear_notifications() { vekrona-dev sh qs -c vekrona-shell ipc call notifications clearAll >/dev/null; }
# A toast hides itself after five seconds, which is less than a few OCR passes take. The centre keeps every notification, buttons included, until it is closed.
open_notification_centre() { vekrona-dev sh qs -c vekrona-shell ipc call notifications toggle >/dev/null; }
close_notification_centre() { vekrona-dev sh qs -c vekrona-shell ipc call notifications close >/dev/null; }

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
