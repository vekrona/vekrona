# shellcheck shell=bash
# shellcheck disable=SC2016 # the bash -c bodies below run on the VM, where their $variables must expand, not here
# Tests run only in the vekrona-dev VM (the e2e scenarios drive it from the host).
# shellcheck source=require-vm.sh
source "$(dirname "${BASH_SOURCE[0]}")/require-vm.sh"
require_vm "${BASH_SOURCE[1]}"
# Every shell test sources this instead of lib/common.sh. die() reports through the system journal, where the
# user's vekrona-errors watcher turns each record into a real entry in the error store, so a test's expected
# failures would land there. The reporter is therefore replaced for this test and for every process it starts.
export VEKRONA_ERROR_REPORTER=/usr/bin/true
# shellcheck source=../lib/common.sh source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
# `vekrona-error report` writes to the journal socket, which feeds the user's real error store. A missing path makes
# any report from a test fail loudly instead.
export VEKRONA_JOURNAL_SOCKET=/nonexistent/vekrona-test-journal-socket
# The same holds for the desktop: a bin tool's die() (lib/vekrona_cli.py) whose report fails, as every report does here,
# falls back to notify-send, which would pop a critical toast on the user's real desktop for every failure a test
# provokes on purpose. An unreachable session bus makes notify-send fail inside the test, where die() reports it on stderr.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/vekrona-test-session-bus

# A test that cannot run here (root has no desktop to toast on, a USB key is held by the host) ends with SKIP_EXIT_STATUS, so that
# tests/stages/run.sh counts and reports it; an exit 0 would read as a pass.
# shellcheck source=skip-status.sh
source "$(dirname "${BASH_SOURCE[0]}")/skip-status.sh"
skip() {
  warn "SKIP: $*"
  exit "$SKIP_EXIT_STATUS"
}

# Root reads every file and may do what the tests expect a regular user to be refused. CI runs the tests as a regular user, so
# this skips (and the runner counts it) only where somebody runs a test as root by hand.
skip_as_root() {
  if ((EUID == 0)); then skip "$1: root is not refused what a regular user is refused"; fi
}
# A test that stands in for root with `unshare -r` needs user namespaces. The guest has them, so a missing one is a failure there;
# the CI container may forbid them, and the test is then skipped and counted, not passed.
require_user_namespaces() {
  unshare -r true 2>/dev/null && return 0
  if in_ci_container; then skip "this container allows no user namespaces"; fi
  die "cannot create a user namespace to stand in for root"
}

# A check that cannot tell is not a negative answer. abort ends the scenario from wherever it is called: a command
# substitution or a predicate that `vekrona-dev until` runs would otherwise end only itself, and the failed check would read as
# an empty answer. The scenario gets a SIGTERM (its EXIT trap runs); in a cleanup it fails the step only, because a SIGTERM
# there would cut the remaining steps short.
abort() {
  printf 'tests/lib.sh: %s\n' "$*" >&2
  [[ -n "${CLEANING_UP:-}" ]] || kill -TERM "$$"
  exit 70
}
# absent CHECK...: whether CHECK, which exits 0 when the thing is there and 1 when it is not, finds it absent. Any other
# status says the check itself broke (the VM is gone, OCR failed): that ends the scenario, and a test that waits for something
# to disappear never passes on a check that could not look.
absent() {
  local status=0
  "$@" || status=$?
  case "$status" in
    0) return 1 ;;
    1) return 0 ;;
    *) abort "cannot tell whether it is absent, '$*' exited $status" ;;
  esac
}
# inactive CHECK...: absent for a systemctl is-active style check, where 0 is active and 3 is "not active".
inactive() {
  local status=0
  "$@" || status=$?
  case "$status" in
    0) return 1 ;;
    3) return 0 ;;
    *) abort "cannot tell whether it is inactive, '$*' exited $status" ;;
  esac
}
export -f abort absent inactive
# stays_absent SEC CHECK...: whether CHECK (see absent) finds the thing absent at every look for SEC seconds. The deadline bounds
# a wait for something that must not happen, and it is no pause: the looks follow each other back to back.
stays_absent() {
  local deadline=$((SECONDS + $1))
  shift
  while ((SECONDS < deadline)); do
    absent "$@" || return 1
  done
}

# Runs every STEP (a function name or a command line) in an errexit subshell of its own, so that a failure inside one step
# ends that step and never keeps the next from running, collects the failures and reports them all. Meant for an EXIT trap,
# `trap 'run_cleanups restore_a restore_b' EXIT`: the script then fails when a step did, and keeps its own status when it
# was failing already. Put the step that is most dangerous to leave undone first (a shim that stays armed, a PAM line that
# refuses every login).
run_cleanups() {
  local script_status=$? step status had_errexit=0 failed=()
  local -x CLEANING_UP=1
  [[ $- == *e* ]] && had_errexit=1
  set +e
  for step in "$@"; do
    (
      set -e
      eval "$step"
    )
    status=$?
    ((status == 0)) || failed+=("$step (exit $status)")
  done
  if ((had_errexit)); then set -e; fi
  ((${#failed[@]} == 0)) && return 0
  for step in "${failed[@]}"; do
    warn "cleanup failed: $step"
  done
  exit "$((script_status == 0 ? 1 : script_status))"
}

# Reruns CHECK... back to back until it succeeds, for at most SEC seconds (a deadline, not a pause); fails after that.
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    ((SECONDS < deadline)) || return 1
  done
}

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
sway_running() { vekrona-dev run pgrep -x sway >/dev/null; }
sway_gone() { absent sway_running; }
# sway can die before it answers the command that ends it, so the status says nothing: sway_gone is the check.
logout_sway() {
  vekrona-dev sh swaymsg exit >/dev/null || true
  vekrona-dev until --timeout 60 -- sway_gone
}
export -f ssh_session_class ssh_session_is_background ssh_session_is_user sway_running sway_gone
replace_ssh_session() { vekrona-dev run bash -c 'sudo systemd-run --no-block loginctl terminate-session "$XDG_SESSION_ID"' >/dev/null; }
ssh_sessions_background() {
  vekrona-dev run sudo bash -c '
printf "XDG_SESSION_CLASS=background\n" >"$1"
grep -q "$1" /etc/pam.d/sshd || sed -i "/^session    include      password-auth/i session    required     pam_env.so envfile=$1" /etc/pam.d/sshd
' _ "$SSH_SESSION_ENV"
  ssh_session_is_background || replace_ssh_session
  vekrona-dev until --timeout 60 -- ssh_session_is_background
}
# The pam_env line goes first: with its file gone, a remaining line would refuse every ssh login. A scenario that restores in
# an EXIT trap lists ssh_sessions_unconfigure first among its cleanups and ssh_sessions_relogin last.
ssh_sessions_unconfigure() {
  vekrona-dev run sudo bash -c 'sed -i "\|$1|d" /etc/pam.d/sshd && rm -f "$1"' _ "$SSH_SESSION_ENV"
}
ssh_sessions_relogin() {
  ssh_session_is_user || replace_ssh_session
  vekrona-dev until --timeout 60 -- ssh_session_is_user
  logout_sway
  vekrona-dev session
}

# The guest's vekrona-idle.service with its own ExecStart and only the idle hint shortened to $1 seconds (a drop-in under
# $XDG_RUNTIME_DIR, so the scenario fails when the unit has no `timeout 300 'vekrona-idlehint yes'`). The caller reloads and restarts the unit.
IDLE_UNIT_DROPIN_SUBDIR=systemd/user/vekrona-idle.service.d
shorten_idlehint() {
  vekrona-dev sh bash -c '
    set -euo pipefail
    dir="$XDG_RUNTIME_DIR/$1"
    exec_start="$(systemctl --user cat vekrona-idle.service | grep "^ExecStart=")"
    shortened="$(sed "s/timeout 300 \(.vekrona-idlehint yes.\)/timeout $2 \1/" <<<"$exec_start")"
    [[ "$shortened" != "$exec_start" ]] || { echo "vekrona-idle.service has no timeout 300 for vekrona-idlehint" >&2; exit 1; }
    mkdir -p "$dir"
    printf "[Service]\nExecStart=\n%s\n" "$shortened" >"$dir/zz-test.conf"
  ' _ "$IDLE_UNIT_DROPIN_SUBDIR" "$1"
}
restore_idlehint() {
  vekrona-dev sh bash -c 'rm -rf "$XDG_RUNTIME_DIR/$1" && systemctl --user daemon-reload && systemctl --user restart vekrona-idle.service' _ "$IDLE_UNIT_DROPIN_SUBDIR"
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

# Stops the guest processes pkill matches; none running is fine, any other failure is reported and returned.
guest_pkill() {
  local status=0
  vekrona-dev run "$@" || status=$?
  ((status <= 1)) || { warn "could not stop in the guest: $* (exit $status)"; return 1; }
}
kill_guest() { guest_pkill pkill "$@"; }
kill_guest_root() { guest_pkill sudo pkill "$@"; }

clear_notifications() { vekrona-dev sh qs -c vekrona-shell ipc call notifications clearAll >/dev/null; }
# A toast hides itself after five seconds, which is less than a few OCR passes take. The centre keeps every notification, buttons included, until it is closed.
open_notification_centre() { vekrona-dev sh qs -c vekrona-shell ipc call notifications toggle >/dev/null; }
close_notification_centre() { vekrona-dev sh qs -c vekrona-shell ipc call notifications close >/dev/null; }
# Where the clickable parts of a notification card sit, measured from the right edge of the screen to their centre. A toast
# floats space2 from the edge, the centre panel has space4 of padding, and a card has space3 of its own; a pill is 34 px wide
# and 12 px from its neighbour.
TOAST_DISMISS_FROM_RIGHT_PX=37
CENTRE_DISMISS_FROM_RIGHT_PX=45
CENTRE_COPY_FROM_RIGHT_PX=91
# The card's own padding right of its close button: a click there is on no button and no text.
CENTRE_CARD_PADDING_FROM_RIGHT_PX=22
# The buttons sit level with the line above the summary, where the card names its sender.
CARD_BUTTONS_ABOVE_SUMMARY_PX=16
screen_width() { vekrona-dev sh bash -c "swaymsg -t get_outputs | jq -r '.[0].rect.width'"; }
# Clicks on the card whose one-word summary is $1, at $2 px from the right edge of the screen, level with the summary or $3 px above it.
click_card() {
  local x y
  read -r x y <<<"$(vekrona-dev see find "^$1\$")"
  [[ -n "${x:-}" ]] || die "the card $1 must be on screen, but OCR found it nowhere"
  vekrona-dev click "$(($(screen_width) - $2))" "$((y - ${3:-0}))"
}

# The bar's clock shows the guest's date, which tests cannot choose while lima's guest agent keeps syncing it from the
# host, and Quickshell's SystemClock never notices a jump until the shell restarts. clock_pin stops the agent, sets
# the date ("YYYY-MM-DD HH:MM:SS") and restarts the shell; clock_restore undoes all three. The guest's seconds of
# uptime carry the real time across the pin, and the agent then syncs the exact time again.
# Without the agent the host's ssh connections make sshd log an error again and again, and a jump of the clock makes
# the error watcher see that record as long unseen: it toasts it again, at an arbitrary moment, over whatever the test
# clicks next. So the watcher is stopped for the pin, and started once the clock is real again, when the record is not stale.
# A jump across midnight fires vekrona-update-night.timer (00:00), which stages an offline update and reboots the VM in the
# middle of the suite, and an evening clock makes the update notice ask its question and take the keyboard. So both are
# stopped for the pin, and the ones that were running are started once the clock is real again (a timer that is started
# computes its next 00:00 from the real time and does not fire for the jump: Persistent=false).
NIGHT_TIMER=vekrona-update-night.timer
UPDATE_NOTIFY_UNITS=(vekrona-update-notify.path vekrona-update-notify.service)
# The unit $1 ("system" or "user") named $2 is active in the guest: 0 yes, 1 no, anything else is a failure of the check.
guest_unit_state_is_active() {
  local scope=$1 unit=$2 status=0
  if [[ "$scope" == system ]]; then
    vekrona-dev run systemctl is-active --quiet "$unit" || status=$?
  else
    vekrona-dev sh systemctl --user is-active --quiet "$unit" || status=$?
  fi
  case "$status" in
    0) return 0 ;;
    3) return 1 ;;
    *) die "cannot read whether the $scope unit $unit is active (exit $status)" ;;
  esac
}
clock_pin() {
  CLOCK_REAL_EPOCH="$(vekrona-dev run date +%s)"
  CLOCK_UPTIME_SEC="$(vekrona-dev run awk '{ print int($1) }' /proc/uptime)"
  CLOCK_NIGHT_TIMER_WAS_ACTIVE=0
  guest_unit_state_is_active system "$NIGHT_TIMER" && CLOCK_NIGHT_TIMER_WAS_ACTIVE=1
  CLOCK_NOTIFY_PATH_WAS_ACTIVE=0
  guest_unit_state_is_active user vekrona-update-notify.path && CLOCK_NOTIFY_PATH_WAS_ACTIVE=1
  vekrona-dev sh systemctl --user stop vekrona-errors.service "${UPDATE_NOTIFY_UNITS[@]}"
  vekrona-dev run sudo systemctl stop "$NIGHT_TIMER"
  vekrona-dev run sudo systemctl stop lima-guestagent
  vekrona-dev run sudo date -s "$1" >/dev/null
  restart_shell
}
clock_restore_time() {
  local uptime
  [[ -n "${CLOCK_UPTIME_SEC:-}" ]] || return 0 # clock_pin failed before it recorded the real time, so it moved nothing
  uptime="$(vekrona-dev run awk '{ print int($1) }' /proc/uptime)"
  vekrona-dev run sudo date -s "@$((CLOCK_REAL_EPOCH + uptime - CLOCK_UPTIME_SEC))" >/dev/null
}
# The path unit starts the update notice at once when updates are pending, and its question would wait ten minutes for the
# next scenario's keyboard: only the unit that was running goes on, and the notice that the start provoked is stopped again.
clock_restore_update_notify() {
  ((${CLOCK_NOTIFY_PATH_WAS_ACTIVE:-0})) || return 0
  vekrona-dev sh systemctl --user start vekrona-update-notify.path
  vekrona-dev sh systemctl --user stop vekrona-update-notify.service
}
clock_restore_night_timer() {
  ((${CLOCK_NIGHT_TIMER_WAS_ACTIVE:-0})) || return 0
  vekrona-dev run sudo systemctl start "$NIGHT_TIMER"
}
# The time goes first and lima's agent right after it, which syncs the exact time again; the rest follows even when a step failed.
clock_restore() {
  run_cleanups clock_restore_time 'vekrona-dev run sudo systemctl start lima-guestagent' \
    'vekrona-dev sh systemctl --user start vekrona-errors.service' clock_restore_update_notify clock_restore_night_timer restart_shell
}

# The agent icon's badge counts the file the error watcher writes. The shell rewrites that file with the count of the unseen
# errors of the store as it starts, so a scenario writes it with unread_set once the shell is up (after clock_pin, which
# restarts it). unread_stash stops the watcher and keeps the original, unread_restore puts both back.
UNREAD_FILE='~/.local/state/vekrona/errors/unread'
UNREAD_STASH='~/.local/state/vekrona/errors/unread.e2e-stash'
# A stash left by a run that was killed holds the original, and the file next to it is that run's: so an existing stash is
# kept, never overwritten, and a restore without a stash leaves the file alone (a redirect would truncate it). Both are safe to
# run twice, and the trap that calls unread_restore can go in before unread_stash.
unread_stash() {
  vekrona-dev sh systemctl --user stop vekrona-errors.service
  vekrona-dev sh bash -c "[[ -e $UNREAD_STASH ]] || cp -p $UNREAD_FILE $UNREAD_STASH"
}
unread_set() { vekrona-dev sh bash -c "echo $1 > $UNREAD_FILE"; }
unread_restore() {
  vekrona-dev sh bash -c "if [[ -e $UNREAD_STASH ]]; then mv $UNREAD_STASH $UNREAD_FILE; fi"
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
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export SCREEN_COLORS PANEL_HEX
# Whether the launcher's (or any other) panel fills the middle of the screen. A screenshot or a colour reading that fails ends
# the scenario: panel_hidden is its negation, and a screen that could not be read has not shown that the panel is gone.
panel_shown() {
  local shot center
  shot="$(vekrona-dev shot)" || abort "cannot take a screenshot"
  center="$(python3 "$SCREEN_COLORS" center "$shot")" || abort "cannot read the colour of the screen's centre in $shot"
  [[ "$center" == "$PANEL_HEX" ]]
}
panel_hidden() { ! panel_shown; }
export -f panel_shown panel_hidden

# The screen's text by OCR. `vekrona-dev see text` exits 0 on a match, 1 when the screen holds no such text and 2 when it could
# not read the screen, so text_absent holds for 1 only. An optional IMAGE as $2 is read instead of a fresh screenshot.
text_shown() { vekrona-dev see text "$@"; }
text_absent() { absent text_shown "$@"; }
export -f text_shown text_absent

# The user journal's lines of the vekrona shell, and how many of them match the extended regex $1. A journalctl that fails is a
# failure, never "no match": the count reads the whole log first, because a pipe would hide journalctl's status behind grep's.
shell_log() { vekrona-dev sh journalctl --user --no-pager -o cat -t vekrona-shell; }
shell_log_count() {
  local log
  log="$(shell_log)" || abort "cannot read the vekrona-shell log"
  grep -cE "$1" <<<"$log" || [[ $? -eq 1 ]]
}
# How many failed commands the shell has logged: the lines the error pipeline turns into entries in the error store.
shell_errors() { shell_log_count 'ERROR.*qml.* exited [0-9]+: '; }
# How many lines of the shell's log are QML errors of its own code.
QML_ERROR_REGEX='ReferenceError|TypeError|is not defined|ERROR'
qml_errors() { shell_log_count "$QML_ERROR_REGEX"; }
# The shell's log lines since the epoch second $1 that match the extended regex $2, none being fine.
shell_log_since_matching() {
  local log
  log="$(vekrona-dev run journalctl --user -u vekrona-shell --since "@$1" --no-pager)" || abort "cannot read the vekrona-shell log since $1"
  grep -E "$2" <<<"$log" || [[ $? -eq 1 ]]
}
export -f shell_log shell_log_count shell_errors qml_errors shell_log_since_matching
export QML_ERROR_REGEX

# Where the guest remembers which drivers it took the keyboards from, so that they can be given back.
UNBOUND_FILE=/tmp/e2e-keyboards-unbound
export UNBOUND_FILE
keyboards_listed() { vekrona-dev sh swaymsg -t get_inputs --raw | jq -r '.[] | select(.type == "keyboard") | .name'; }
no_keyboards() {
  local names
  names="$(keyboards_listed)" || abort "cannot list the keyboards"
  [[ -z "$names" ]]
}
keyboards_present() { ! no_keyboards; }
export -f keyboards_listed no_keyboards keyboards_present

# The VM's keyboard is not a USB device (QMP injects it), so it cannot be hot-unplugged. Unbinding its driver removes the
# input device the way a USB KVM switch or a resume does: Sway drops it from get_inputs and emits an input event, and
# binding it again adds it back.
# xremap is a uinput keyboard Sway lists too, and it has no driver to unbind, so it stops for the time the keyboards are away
# (it would keep running, waiting for one). xremap.path would start it again at once (the Wayland socket is still there), so it stops too.
unplug_keyboards() {
  vekrona-dev run sudo systemctl stop xremap.path xremap.service
  unbind_keyboards
}
# The same without xremap: the keyboards that have a driver go, xremap stays and sees them leave, as it does when a keyboard is unplugged.
unbind_keyboards() {
  local name names
  mapfile -t names < <(keyboards_listed | grep -vx xremap || [[ $? -eq 1 ]])
  for name in "${names[@]}"; do
    vekrona-dev run sudo bash -c '
for input in /sys/class/input/input*; do
  [[ "$(<"$input/name")" == "$1" ]] || continue
  parent="$(dirname "$(dirname "$(readlink -f "$input")")")"
  [[ -e "$parent/driver" ]] || { echo "keyboard $1 has no driver to unbind" >&2; exit 1; }
  echo "$(readlink -f "$parent/driver") $(basename "$parent")" >>"$2"
  basename "$parent" >"$parent/driver/unbind"
done
' _ "$name" "$UNBOUND_FILE"
  done
}
# Binds the drivers unbind_keyboards unbound; xremap, if it still runs, picks the keyboards up by itself.
rebind_keyboards() {
  vekrona-dev run sudo bash -c '
[[ -e "$1" ]] || exit 0
while read -r driver device; do
  echo "$device" >"$driver/bind"
done <"$1"
rm -f "$1"
' _ "$UNBOUND_FILE"
  vekrona-dev until --timeout 60 -- keyboards_present
}
plug_keyboards() {
  rebind_keyboards
  # The keyboards are listed again first, so that xremap starts with them.
  vekrona-dev run sudo systemctl start xremap.path
  # The path unit and the restarts of the scenarios before it may have used up the unit's start limit.
  vekrona-dev run sudo systemctl reset-failed xremap.service
  vekrona-dev run sudo systemctl restart xremap.service
}
# How many lines of the shell's log mention the keyboard widget: it logs nothing about a keyboard that is gone or a query that Sway dropped.
keyboard_errors() { shell_log_count 'Keyboard:'; }
export -f keyboard_errors

# The root-side update check owns /var/lib/vekrona/updates.json, which stage 40 seeds. A scenario sets its own content and puts the
# original back on exit with updates_restore; the user-side "already told" memory is cleared with updates_forget.
UPDATES_JSON=/var/lib/vekrona/updates.json
UPDATES_STASH=/var/lib/vekrona/updates.json.e2e-stash
# A stash left by a run that was killed holds the original, so an existing stash is kept, and a restore without one does nothing:
# both are safe to run twice, and the trap that calls updates_restore can go in before updates_stash.
updates_stash() { vekrona-dev run sudo bash -c '[[ -e "$2" ]] || cp -p "$1" "$2"' _ "$UPDATES_JSON" "$UPDATES_STASH"; }
# Replaced by rename, like the root writer does, so a watcher sees what it sees in production.
updates_write() { vekrona-dev run sudo bash -c 'install -d /var/lib/vekrona && printf "%s\n" "$1" >"$2.tmp" && chmod 644 "$2.tmp" && mv "$2.tmp" "$2"' _ "$1" "$UPDATES_JSON"; }
updates_restore() { vekrona-dev run sudo bash -c 'if [[ -e "$2" ]]; then mv "$2" "$1"; fi' _ "$UPDATES_JSON" "$UPDATES_STASH"; }
updates_forget() { vekrona-dev run bash -c 'rm -f "$HOME/.local/state/vekrona/update-notified"'; }
# A check result with pending updates; $1 is the version claude-code updates to.
updates_pending_json() {
  printf '{"checked":"2026-10-09T09:00:03+02:00","pending":true,"night_armed":true,"groups":[{"name":"System packages","items":[{"name":"claude-code","from":"2.1.0","to":"%s"}]}]}' "$1"
}

# The launcher's state as JSON: {open, mode, query, view, selectedId, armed, actionsOpen, rows, empty, tabs}, where empty says the list shows its "No matches" or "Nothing to show" line, and tabs lists the mode tabs as {slash, active, x, y}, the centre of each in screen pixels. Tests assert on it, not on OCR of small text.
launcher_state() { vekrona-dev sh qs -c vekrona-shell ipc call launcher state; }
# Whether the jq filter holds for the launcher's state, e.g. launcher_is '.mode == "calc" and .rows == 0'.
launcher_is() { launcher_state | jq -e "$1" >/dev/null; }
launcher_open() { launcher_is '.open'; }
launcher_closed() { launcher_is '.open | not'; }
# The shell answers an IPC call once it is up; while it loads, qs says it is not ready and still exits 0. The guest's own stderr is merged
# inside the guest: the host-side vekrona-dev may print warnings of its own (a missing locale).
shell_ready() { [[ "$(vekrona-dev sh bash -c 'qs -c vekrona-shell ipc call launcher state 2>&1' | jq -r '.open' 2>/dev/null)" =~ ^(true|false)$ ]]; }
# Starts the shell again, so that it meets the services that came up after it, and waits until it answers. A scenario that
# follows another within seconds would meet systemd's start limit (five starts in ten seconds) and find the shell failed.
restart_shell() {
  vekrona-dev sh systemctl --user reset-failed vekrona-shell.service
  vekrona-dev sh systemctl --user restart vekrona-shell.service
  vekrona-dev until --timeout 60 -- shell_ready
}
# A scenario that opens the launcher leaves it closed: an open one keeps the keyboard from the next scenario.
close_launcher() {
  launcher_open || return 0
  vekrona-dev sh qs -c vekrona-shell ipc call launcher toggle >/dev/null
  vekrona-dev until --timeout 60 -- launcher_closed
}
# Whether the mode tab with the slash $1 ("" is Apps) is the only lit one.
launcher_tab_lit() { launcher_is ".tabs | map(select(.active) | .slash) == [\"$1\"]"; }
# Clicks the mode tab with the slash $1 ("" is Apps), where the launcher's state says it is.
click_launcher_tab() {
  local centre x y
  centre="$(launcher_state | jq -er --arg slash "$1" '.tabs[] | select(.slash == $slash) | "\(.x) \(.y)"')"
  read -r x y <<<"$centre"
  vekrona-dev click "$x" "$y"
}
export -f shell_ready
export -f launcher_state launcher_is launcher_open launcher_closed launcher_tab_lit click_launcher_tab

# One "<con id> <x> <y>" line per window whose app_id matches the regex $1, in the sway tree's layout order.
window_rects() { vekrona-dev sh bash -c "swaymsg -t get_tree | jq -r '.. | objects | select(.pid? != null and ((.app_id? // \"\") | test(\"$1\"))) | \"\(.id) \(.rect.x) \(.rect.y)\"'"; }
export -f window_rects

# Windows and focus, from sway's tree. The queries run with pipefail, so a swaymsg that fails is a failure, not an empty tree.
window_count() { vekrona-dev sh bash -c 'set -o pipefail; swaymsg -t get_tree | jq "[.. | objects | select((.type? == \"con\" or .type? == \"floating_con\") and .pid? != null)] | length"'; }
# Whether a window with the app_id (or X11 class) $1 is open: 0 yes, 1 (jq's false) no, anything else is a failure of the query.
window_open() {
  vekrona-dev sh bash -c 'set -o pipefail; swaymsg -t get_tree | jq -e --arg c "$1" "[.. | objects | select((.app_id? == \$c) or (.window_properties?.class? == \$c))] | length > 0" >/dev/null' _ "$1"
}
window_closed() { absent window_open "$1"; }
focused_app_id() { vekrona-dev sh bash -c 'set -o pipefail; swaymsg -t get_tree | jq -r "[recurse(.nodes[]?, .floating_nodes[]?) | select(.focused)][0].app_id // \"none\""'; }
focused_is() { [[ "$(focused_app_id)" == "$1" ]]; }
# Whether the flatpak app $1 runs. `flatpak ps` is read whole first: in a pipe its failure would read as "not running".
flatpak_running() {
  local apps
  apps="$(vekrona-dev run flatpak ps --columns=application)" || abort "cannot list the running flatpak apps"
  grep -qx "$1" <<<"$apps"
}
flatpak_stopped() { ! flatpak_running "$1"; }
export -f window_count window_open window_closed focused_app_id focused_is flatpak_running flatpak_stopped

# The keyboard layout pill. Sway splits a command at commas, so the layout list is quoted inside the command.
set_layouts() { vekrona-dev sh swaymsg "input type:keyboard xkb_layout \"$1\""; }
# A changed code keeps the pill in place (its width is fixed); other text containing EN or UA sits elsewhere on screen. The pill
# is at PILL_X, which a scenario sets from the screen once the keymap has two layouts. Exit 0 when the code $1 is in the pill,
# 1 when it is not on screen or sits elsewhere, 2 when the screen could not be read.
PILL_DRIFT_PX=20
code_shown() {
  local center x status=0
  center="$(vekrona-dev see find "$1")" || status=$?
  ((status == 0)) || return "$status"
  x="${center%% *}"
  ((x > PILL_X - PILL_DRIFT_PX && x < PILL_X + PILL_DRIFT_PX))
}
code_hidden() { absent code_shown "$1"; }
export -f set_layouts code_shown code_hidden
export PILL_DRIFT_PX

# The lock screen (vekrona-lock) and its security-key watcher. systemctl is-active exits 3 for a unit that is not active, and
# anything else (ssh 255) is a guest that could not be asked.
lock_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-lock; }
lock_inactive() { inactive lock_active; }
key_watcher_running() { vekrona-dev sh pgrep -f fido-keys.sh >/dev/null; }
# OCR drops the small texts of the lock screen when the clock is in the picture, so only the lower part of the screen is read.
lock_text_shown() {
  local shot lower status=0
  shot="$(vekrona-dev shot)" || abort "cannot take a screenshot"
  lower="${shot%.png}-lower.png"
  magick "$shot" -gravity south -crop 100%x55%+0+0 +repage "$lower" || abort "cannot crop the screenshot $shot"
  text_shown "$1" "$lower" || status=$?
  rm -f "$shot" "$lower"
  return "$status"
}
lock_text_absent() { absent lock_text_shown "$1"; }
export -f lock_active lock_inactive key_watcher_running lock_text_shown lock_text_absent

# Reboots. An unreachable guest answers nothing, which must not count as a new boot.
boot_id() { vekrona-dev run cat /proc/sys/kernel/random/boot_id; }
booted_again() {
  local now
  now="$(boot_id 2>/dev/null)" || return 1
  [[ "$now" != "$1" ]]
}
greeter_up() { vekrona-dev run systemctl is-active --quiet greetd 2>/dev/null; }
export -f boot_id booted_again greeter_up
# vekrona-dev installs the guest's checkout here, below the home directory.
GUEST_CHECKOUT_SUBPATH=.local/share/vekrona

# The emulated USB audio card of the audio scenarios. The VM has no sound hardware: QEMU's emulated USB audio card stands in
# for the interface behind the KVM, and a null sink for the onboard one (an ALSA dummy card cannot be unloaded again while
# WirePlumber holds it). Port 1 keeps the card's name (alsa_card.usb-...-1-00) the same on every plug, as the Scarlett's is,
# which is what lets WirePlumber recognise it and restore what it stored. The audiodev id is the one Lima's QEMU command line
# defines (-audiodev none,id=snd0). A scenario calls audio_setup, traps audio_teardown, and waits with audio_expect.
USB_AUDIO_ID=vekrona-audio
USB_AUDIO_ADD="{\"driver\":\"usb-audio\",\"bus\":\"usb-bus.0\",\"id\":\"$USB_AUDIO_ID\",\"port\":\"1\",\"audiodev\":\"snd0\"}"
USB_AUDIO_DEL="{\"id\":\"$USB_AUDIO_ID\"}"
USB_AUDIO_SINK=usb-QEMU
FALLBACK_SINK=VekronaFallbackSink
AUDIO_STREAM=pw-cat
AUDIO_GUEST_DIR=/tmp/audio-e2e
AUDIO_GUEST_STATE="$AUDIO_GUEST_DIR/audio_state.py"
AUDIO_STATE_SOURCE="$(dirname "${BASH_SOURCE[0]}")/e2e/audio_state.py"
usb_audio_add() { vekrona-dev qmp device_add "$USB_AUDIO_ADD" >/dev/null; }
usb_audio_del() { vekrona-dev qmp device_del "$USB_AUDIO_DEL" >/dev/null; }
# The wpctl id of the USB card; nothing when it is not listed, a failing wpctl is an error (a pipe would read it as "not listed").
usb_card_id() {
  vekrona-dev run bash -c 'status="$(wpctl status)" || exit 70; awk "$1" <<<"$status"' _ \
    '/QEMU USB Audio +\[alsa\]/ { if (match($0, /[0-9]+\./)) { print substr($0, RSTART, RLENGTH - 1); exit } }'
}
# 0 when the card is listed, 1 when it is not, and the failure of wpctl otherwise.
usb_card_listed() {
  local id status=0
  id="$(usb_card_id)" || status=$?
  ((status == 0)) || return "$status"
  [[ -n "$id" ]]
}
usb_card_unlisted() { absent usb_card_listed; }
# True when the default sink contains $1, the stream plays on it, and no card with a usable profile is left on "off" (unless
# $2 is --cards-may-be-off).
audio_graph_is() { vekrona-dev run python3 "$AUDIO_GUEST_STATE" --default-sink "$1" --stream "$AUDIO_STREAM" "${@:2}" 2>/dev/null; }
export -f usb_card_id usb_card_listed usb_card_unlisted audio_graph_is
export AUDIO_GUEST_STATE AUDIO_STREAM
# Waits for audio_graph_is, or dies with $2 and what differs.
audio_expect() {
  local sink="$1" failure="$2"
  vekrona-dev until --timeout "${STEP_TIMEOUT_SEC:-60}" -- audio_graph_is "$sink" "${@:3}" \
    || die "$failure: $(vekrona-dev run python3 "$AUDIO_GUEST_STATE" --default-sink "$sink" --stream "$AUDIO_STREAM" "${@:3}" 2>&1 || true)"
}
audio_setup() {
  vekrona-dev run mkdir -p "$AUDIO_GUEST_DIR"
  vekrona-dev run bash -c 'cat >"$1"' _ "$AUDIO_GUEST_STATE" <"$AUDIO_STATE_SOURCE"
  AUDIO_FALLBACK_MODULE="$(vekrona-dev sh pactl load-module module-null-sink "sink_name=$FALLBACK_SINK")"
}
audio_stream_start() { vekrona-dev spawn "$AUDIO_GUEST_DIR/stream.log" -- pw-cat -p --raw --rate 48000 --channels 2 --format s16 /dev/zero; }
# The card may be gone already (the scenario unplugged it): QEMU then says so, and that is the state wanted.
audio_unplug_card() {
  local out
  out="$(vekrona-dev qmp device_del "$USB_AUDIO_DEL" 2>&1)" && return 0
  [[ "$out" == *"not found"* ]] || { echo "$out" >&2; return 1; }
}
audio_unload_fallback_sink() {
  [[ -n "${AUDIO_FALLBACK_MODULE:-}" ]] || return 0 # audio_setup failed before it loaded the null sink
  vekrona-dev sh pactl unload-module "$AUDIO_FALLBACK_MODULE"
}
audio_teardown() {
  run_cleanups audio_unplug_card "kill_guest -x $AUDIO_STREAM" audio_unload_fallback_sink 'vekrona-dev run rm -rf "$AUDIO_GUEST_DIR"'
}

# Writes stdin to the executable $1. Callers pass the body as a quoted heredoc (<<'F'), so that nothing in it, backticks
# included, is expanded while the fake is written.
write_fake() { cat >"$1" && chmod +x "$1"; }

# Guard: a test process killed by a signal must not drop a coredump on the host, where vekrona-error would record it as a
# real crash. systemd-coredump honors a core size limit of 0 (its %c), and every process a test starts inherits it.
ulimit -c 0
# Guard: a runaway test (a fake that runs itself, a loop that forks without pause) must hit a process limit within seconds
# instead of the terminal's cgroup limit, which takes the terminal and every program in it down. The kernel counts
# every thread of the user's processes against the limit, so it sits above their current thread count by a margin that
# grows with it: a busy machine forks more between two looks. The limit is hard, so it applies only where a test may fail the
# machine it runs on: the guest and the CI container, never the host that drives the guest, where it would make the driver
# (limactl, ssh, the e2e scenario's own forks) fail with EAGAIN.
# A shell started by a test sources this file again, and by then its parent's cap is the hard limit: it can only be lowered.
if in_vekrona_dev_guest || in_ci_container; then
  process_threads=$(ps -eLo pid= -u "$UID" | wc -l)
  process_cap=$((process_threads * 2 + 2000))
  inherited_cap="$(ulimit -u)"
  if [[ "$inherited_cap" == unlimited || "$inherited_cap" -gt "$process_cap" ]]; then
    ulimit -u "$process_cap"
  fi
fi
