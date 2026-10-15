# shellcheck shell=bash
# shellcheck disable=SC2016 # the bash -c bodies below run on the VM, where their $variables must expand, not here
# Every shell test sources this instead of lib/common.sh. die() reports through the system journal, where the
# user's vekrona-errors watcher turns each record into a real entry in the error store, so a test's expected
# failures would land there. The reporter is therefore replaced for this test and for every process it starts.
export VEKRONA_ERROR_REPORTER=/usr/bin/true
# shellcheck source=../lib/common.sh source-path=SCRIPTDIR
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

# The VM forbids suspend (AllowSuspend=no, its virtio-gpu cannot resume), which makes logind refuse before it emits
# anything. These drop-ins under /run allow it and replace the suspend itself with /usr/bin/true, so the VM keeps
# running while logind still emits PrepareForSleep, which scenarios wait on. /run is gone after a reboot.
FAKE_SUSPEND_SLEEP_DIR=/run/systemd/sleep.conf.d
FAKE_SUSPEND_UNIT_DIR=/run/systemd/system/systemd-suspend.service.d
fake_suspend() {
  vekrona-dev run sudo bash -c '
install -d "$1" "$2"
printf "[Sleep]\nAllowSuspend=yes\n" >"$1/zz-test.conf"
printf "[Service]\nExecStart=\nExecStart=/usr/bin/true\n" >"$2/zz-test.conf"
systemctl daemon-reload
' _ "$FAKE_SUSPEND_SLEEP_DIR" "$FAKE_SUSPEND_UNIT_DIR"
}
real_suspend() {
  vekrona-dev run sudo bash -c 'rm -rf "$1/zz-test.conf" "$2" && systemctl daemon-reload' _ "$FAKE_SUSPEND_SLEEP_DIR" "$FAKE_SUSPEND_UNIT_DIR"
}
# True when the guest file $1, which a PrepareForSleep watcher writes, holds a signal.
sleep_signalled() { vekrona-dev run grep -q '"data":\[true\]' "$1"; }
export -f sleep_signalled

clear_notifications() { vekrona-dev sh qs -c vekrona-shell ipc call notifications clearAll >/dev/null; }
# A toast hides itself after five seconds, which is less than a few OCR passes take. The centre keeps every notification, buttons included, until it is closed.
open_notification_centre() { vekrona-dev sh qs -c vekrona-shell ipc call notifications toggle >/dev/null; }
close_notification_centre() { vekrona-dev sh qs -c vekrona-shell ipc call notifications close >/dev/null; }

# The bar's clock shows the guest's date, which tests cannot choose while lima's guest agent keeps syncing it from the
# host, and Quickshell's SystemClock never notices a jump until the shell restarts. clock_pin stops the agent, sets
# the date ("YYYY-MM-DD HH:MM:SS") and restarts the shell; clock_restore undoes all three. The guest's seconds of
# uptime carry the real time across the pin, and the agent then syncs the exact time again.
clock_pin() {
  CLOCK_REAL_EPOCH="$(vekrona-dev run date +%s)"
  CLOCK_UPTIME_SEC="$(vekrona-dev run awk '{ print int($1) }' /proc/uptime)"
  vekrona-dev run sudo systemctl stop lima-guestagent
  vekrona-dev run sudo date -s "$1" >/dev/null
  vekrona-dev sh systemctl --user restart vekrona-shell.service
}
clock_restore() {
  local uptime
  uptime="$(vekrona-dev run awk '{ print int($1) }' /proc/uptime)"
  vekrona-dev run sudo date -s "@$((CLOCK_REAL_EPOCH + uptime - CLOCK_UPTIME_SEC))" >/dev/null
  vekrona-dev run sudo systemctl start lima-guestagent
  vekrona-dev sh systemctl --user restart vekrona-shell.service
}

# The agent icon's badge counts the file the error watcher writes. The shell watches that file only when it exists as the
# shell starts, so a scenario writes it with unread_set and then restarts the shell (clock_pin does). unread_stash stops
# the watcher and keeps the original, unread_restore puts both back.
UNREAD_FILE='~/.local/state/vekrona/errors/unread'
UNREAD_STASH='~/.local/state/vekrona/errors/unread.e2e-stash'
unread_stash() {
  vekrona-dev sh systemctl --user stop vekrona-errors.service
  vekrona-dev sh bash -c "if [[ -e $UNREAD_FILE ]]; then cp -p $UNREAD_FILE $UNREAD_STASH; else rm -f $UNREAD_STASH; fi"
}
unread_set() { vekrona-dev sh bash -c "mkdir -p ~/.local/state/vekrona/errors && echo $1 > $UNREAD_FILE"; }
unread_restore() {
  vekrona-dev sh bash -c "if [[ -e $UNREAD_STASH ]]; then cat $UNREAD_STASH > $UNREAD_FILE && rm $UNREAD_STASH; else rm -f $UNREAD_FILE; fi"
  vekrona-dev sh systemctl --user start vekrona-errors.service
}

# The bar's right side is right-aligned, so the x of its leftmost widget moves whenever a widget appears or changes width.
bar_left_edge() {
  python3 "$VEKRONA_ROOT/tests/e2e/bar-left-edge.py" "$(vekrona-dev shot)" \
    "$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))" \
    "$(vekrona_token_get size size-icon-s)" "$(vekrona_token_get spacing space-2)"
}
# A fresh session shows no weather pill until the weather unit's first run, 30 s in, has written its file.
weather_written() { vekrona-dev run bash -c 'test -e ~/.local/state/vekrona/weather.json'; }
export -f weather_written
# Waits until no widget is still on its way, then prints the bar's left edge: the weather pill is in, and two
# screenshots in a row agree.
settled_bar_left_edge() {
  vekrona-dev until --timeout 90 -- weather_written || die "the weather unit never wrote its file, so the bar never showed its pill"
  local edge next attempt
  edge="$(bar_left_edge)"
  for attempt in $(seq 20); do
    next="$(bar_left_edge)"
    [[ "$next" == "$edge" ]] && { echo "$edge"; return; }
    edge="$next"
  done
  die "the left edge of the bar kept moving: x=$edge after $attempt screenshots"
}

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

# The launcher's state as JSON: {open, mode, query, view, selectedId, armed, actionsOpen, rows, empty}, where empty says the list shows its "No matches" or "Nothing to show" line. Tests assert on it, not on OCR of small text.
launcher_state() { vekrona-dev sh qs -c vekrona-shell ipc call launcher state; }
# Whether the jq filter holds for the launcher's state, e.g. launcher_is '.mode == "calc" and .rows == 0'.
launcher_is() { launcher_state | jq -e "$1" >/dev/null; }
launcher_open() { launcher_is '.open'; }
launcher_closed() { launcher_is '.open | not'; }
export -f launcher_state launcher_is launcher_open launcher_closed

# One "<con id> <x> <y>" line per window whose app_id matches the regex $1, in the sway tree's layout order.
window_rects() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '.. | objects | select(.pid? != null and ((.app_id? // \"\") | test(\"$1\"))) | \"\(.id) \(.rect.x) \(.rect.y)\"'"; }
export -f window_rects

# Guard: a test process killed by a signal must not drop a coredump on the host, where vekrona-error would record it as a
# real crash. systemd-coredump honors a core size limit of 0 (its %c), and every process a test starts inherits it.
ulimit -c 0
