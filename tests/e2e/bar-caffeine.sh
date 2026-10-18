#!/usr/bin/env bash
set -euo pipefail

# The keep-awake menu in the bar: its pill follows the session, its popout starts and ends every kind of session, and the
# CLI refuses what it cannot wait for. Real keys and clicks, no scroll wheel (vekrona-dev has none): the until time is
# driven with Tab and Up, and typed into its field.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
FILE_IDLE_SEC=60
SHORT_SESSION=5s
HYPER_SHIFT_C=super-ctrl-alt-shift-c
# OCR cannot read the pill's small bold value, and the pill may show none. An active pill is filled with the selected color,
# which the bar otherwise shows only on the current workspace, so the count of those pixels in the bar tells the two states apart.
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_S_PX="$(vekrona_token_get size size-icon-s)"
GROUP_JOIN_PX="$(vekrona_token_get spacing space-2)"
SELECTED_HEX="$(vekrona_token_get color selected dark)"
# Inside the idle pill and the active one alike: the idle pill is its icon plus two paddings, and the edge is the icon's ink.
PILL_CLICK_OFFSET_PX=8
# The until picker defaults to the next whole hour, so from 10:10 it holds 11:00 and one Up on the time field makes it 11:05
# today. The pin keeps the test off midnight, where the default is already tomorrow.
PINNED_NOW="2026-10-16 10:10:00"
UNTIL_TIME=11:05
PICKED_DAY=20
PICKED_DAY_STAMP="2026-10-20 14:30"
PICKED_DAY_TARGET="Tue 14:30"
# Tab order of the idle popout: five presets, the day pill, then the time field.
TABS_TO_TIME_FIELD=7
WINDOW_APP_ID=e2ecaffeine
DOWNLOAD_LABEL=x.iso
PARTIAL_NAME=AbCd.part
UNIT=vekrona-caffeine.service
END_TIMER=vekrona-caffeine-end.timer
END_TIMER_SERVICE=vekrona-caffeine-end.service
MONITOR_LOG=/tmp/vekrona-e2e-caffeine-notify.log
WRITER_LOG=/tmp/vekrona-e2e-caffeine-writer.log
WINDOW_LOG=/tmp/vekrona-e2e-caffeine-window.log
FLUSHES=0

status() { vekrona-dev sh vekrona-caffeine status; }
status_matches() { [[ "$(status)" =~ $1 ]]; }
status_off() { [[ "$(status)" == off ]]; }
unit_inactive() { [[ "$(vekrona-dev sh systemctl --user show -p ActiveState --value "$UNIT")" == inactive ]]; }
timers() { vekrona-dev sh systemctl --user list-timers --all --no-legend; }
# The listing is read whole first: a systemctl that fails must not read as "no end timer" to the checks that expect none.
end_timer_listed() { local listing; listing="$(timers)" || abort "cannot list the user timers"; grep -qF "$END_TIMER" <<<"$listing"; }
end_timer_at() { local listing; listing="$(timers)" || abort "cannot list the user timers"; grep -F "$END_TIMER" <<<"$listing" | grep -qF " $1 "; }
# Finds the Start button and keeps where, for type_time: one screenshot that shows it is not a promise that the next does.
# The keep-awake singleton answers an empty line once it is loaded; before that qs says it is not ready and still exits 0.
caffeine_ready() { [[ -z "$(vekrona-dev sh bash -c 'qs -c vekrona-shell ipc call caffeine refresh 2>&1')" ]]; }
start_listed() { local position; position="$(vekrona-dev see find '^Start$')" && printf '%s\n' "$position" >"$START_POSITION_FILE"; }
monitor_has() { vekrona-dev run grep -qF -- "$1" "$MONITOR_LOG"; }
bar_edge() {
  local shot edge
  shot="$(vekrona-dev shot)"
  edge="$(python3 "$ROOT/tests/e2e/bar-left-edge.py" "$shot" "$BAR_HEIGHT_PX" "$ICON_S_PX" "$GROUP_JOIN_PX")"
  rm -f "$shot"
  echo "$edge"
}
selected_pixels() {
  local shot count
  shot="$(vekrona-dev shot)"
  count="$(python3 "$ROOT/tests/e2e/screen_colors.py" bar-count "$shot" "$SELECTED_HEX" "$BAR_HEIGHT_PX")"
  rm -f "$shot"
  echo "$count"
}
pill_active() { (($(selected_pixels) > IDLE_SELECTED_PIXELS)); }
pill_idle() { (($(selected_pixels) == IDLE_SELECTED_PIXELS)); }
export -f bar_edge selected_pixels pill_active pill_idle
export ROOT BAR_HEIGHT_PX ICON_S_PX GROUP_JOIN_PX SELECTED_HEX

START_POSITION_FILE="$(mktemp)"
export START_POSITION_FILE
export -f caffeine_ready status status_matches status_off unit_inactive timers end_timer_listed end_timer_at start_listed monitor_has
export UNIT END_TIMER MONITOR_LOG

within() { vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- "$@"; }

# How many "Keep-awake ended" toasts the bus has carried since the monitor started.
ended_toasts() { vekrona-dev run grep -cF 'string "Keep-awake ended"' "$MONITOR_LOG" || [[ $? -eq 1 ]]; }

# The monitor reads the bus asynchronously. A toast sent now and seen by the monitor puts every earlier toast in the log.
flush_toasts() {
  FLUSHES=$((FLUSHES + 1))
  vekrona-dev sh notify-send -a e2e "flush $FLUSHES"
  within monitor_has "flush $FLUSHES"
}

# The session's unit logs a failure the moment one happens, and its end is the last thing it does. Only this run's lines count.
assert_unit_never_failed() {
  within unit_inactive
  local lines
  lines="$(vekrona-dev sh journalctl --user --no-pager -o cat --after-cursor "$JOURNAL_CURSOR" -u "$UNIT" -u "$END_TIMER_SERVICE")"
  if grep -Eqi 'fail|exit-code|status=[1-9]' <<<"$lines"; then
    echo "$lines" >&2
    die "$UNIT logged a failure"
  fi
}

# The popout is open when its first heading shows; the pill sits at PILL_X, PILL_Y.
open_popout() {
  vekrona-dev click "$PILL_X" "$PILL_Y"
  within text_shown 'Stay awake for'
}

downloads_dir() { vekrona-dev sh xdg-user-dir DOWNLOAD; }

remove_downloads_and_logs() {
  vekrona-dev sh bash -c 'd=$(xdg-user-dir DOWNLOAD); rm -f "$d"/*.iso "$d"/*.part "$@"' _ "$MONITOR_LOG" "$WRITER_LOG" "$WINDOW_LOG"
}

# The clock goes first: a pinned clock is what every later scenario would meet.
cleanup() {
  rm -f "$START_POSITION_FILE"
  run_cleanups clock_restore 'vekrona-dev sh vekrona-caffeine off' 'kill_guest -x ping' 'kill_guest -x dbus-monitor' 'kill_guest -x foot' remove_downloads_and_logs
}

vekrona-dev session
trap cleanup EXIT
vekrona-dev sh vekrona-caffeine off
clock_pin "$PINNED_NOW"
# The shell restarted: a session started before it is up would never reach the pill.
within caffeine_ready
clear_notifications
vekrona-dev move 600 500
JOURNAL_CURSOR="$(vekrona-dev sh journalctl --user -n 0 --show-cursor | sed -n 's/^-- cursor: //p')"
[[ -n "$JOURNAL_CURSOR" ]] || die "cannot read the user journal's cursor"
vekrona-dev spawn "$MONITOR_LOG" -- dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'"
IDLE_EDGE="$(settled_bar_left_edge)"
IDLE_SELECTED_PIXELS="$(selected_pixels)"
export IDLE_SELECTED_PIXELS
PILL_X=$((IDLE_EDGE + PILL_CLICK_OFFSET_PX))
PILL_Y=$((BAR_HEIGHT_PX / 2))
export PILL_X PILL_Y
flush_toasts

# 1. The key toggles the session, and the pill follows it. A 1h session has a deadline, but the pill's clock only ticks each minute, so only the shell's refresh IPC can turn it active in time.
vekrona-dev key "$HYPER_SHIFT_C"
within pill_active
status_matches '^kind=for end=[0-9]+ preset=1h target=1h$' || die "Hyper+Shift+c must start a 1h session, but status says: $(status)"
log "ok: Hyper+Shift+c makes the pill active, with a 1h session"

vekrona-dev key "$HYPER_SHIFT_C"
within pill_idle
within status_off
log "ok: Hyper+Shift+c again turns the pill and the session off"

# 2. Preset, then End session: exactly one end toast.
clear_notifications
open_popout
vekrona-dev click-text '^2h$'
within status_matches '^kind=for end=[0-9]+ preset=2h target=2h$'
within text_absent 'Stay awake for'
log "ok: clicking 2h starts a for session with preset=2h and closes the popout"

flush_toasts
ended_before="$(ended_toasts)"
clear_notifications
open_popout
vekrona-dev click-text '^End$'
within status_off
within text_absent 'Stay awake for'
assert_unit_never_failed
flush_toasts
ended_after="$(ended_toasts)"
((ended_after == ended_before + 1)) || die "ending a session must toast once, but the bus carried $((ended_after - ended_before)) end toasts"
log "ok: End session turns the session off and toasts its end exactly once"

# 3. Until, by keys alone: Tab to the time field, Up steps five minutes, Enter starts. Starting another session takes the end timer down with it.
clear_notifications
open_popout
tabs=()
for _ in $(seq "$TABS_TO_TIME_FIELD"); do tabs+=(tab); done
vekrona-dev key "${tabs[@]}" up ret
within status_matches "^kind=until end=[0-9]+ preset=- target=$UNTIL_TIME\$"
within end_timer_at "$UNTIL_TIME:00"
within text_absent 'Stay awake for'
log "ok: Tab, Up and Enter begin an until session for $UNTIL_TIME and close the popout, and $END_TIMER is armed for it"

flush_toasts
ended_before="$(ended_toasts)"
vekrona-dev sh vekrona-caffeine for 1h
within status_matches '^kind=for end=[0-9]+ preset=1h target=1h$'
end_timer_listed || die "a for session arms its own $END_TIMER, but none is listed"
! end_timer_at "$UNTIL_TIME:00" || die "the until session's $END_TIMER must be gone once for 1h replaced it, but it still fires at $UNTIL_TIME:00"
flush_toasts
[[ "$(ended_toasts)" == "$ended_before" ]] || die "replacing a session must not toast an end"
log "ok: for 1h replaces the until session: the old timer is gone, and no end toast"
vekrona-dev sh vekrona-caffeine off
within status_off
assert_unit_never_failed

# OCR reads the field's slashed zeros as nines, and the bar's clock looks like a time too, so the field is found by its
# neighbour: it ends one gap left of the Start pill, which is 80 px from the field's middle to the middle of the word Start.
START_TO_TIME_FIELD_PX=80
# Replaces the text of the until time field: a click focuses it, and ctrl-a selects the text so that what is typed replaces it.
type_time() {
  local x y
  within start_listed
  read -r x y <"$START_POSITION_FILE"
  vekrona-dev click "$((x - START_TO_TIME_FIELD_PX))" "$y"
  vekrona-dev key ctrl-a
  vekrona-dev type "$1"
}

# 3b. Until, with the mouse and the keyboard: the day pill opens a month grid, a click on a day picks it, and a time typed into the field decides the minute.
clear_notifications
open_popout
vekrona-dev click-text '^Today$'
within text_shown 'October 2026'
vekrona-dev click-text "^$PICKED_DAY\$"
within text_shown 'Tue 20 Oct'
within text_absent 'October 2026'
type_time 14:30
vekrona-dev key ret
within status_matches "^kind=until end=$(vekrona-dev sh date -d "$PICKED_DAY_STAMP" +%s) preset=- target=$PICKED_DAY_TARGET\$"
within text_absent 'Stay awake for'
log "ok: a day picked in the month grid and 14:30 typed into the time field start an until session for $PICKED_DAY_TARGET"
vekrona-dev sh vekrona-caffeine off
within status_off
assert_unit_never_failed

# 3c. A time the field cannot read or that is past is explained, starts nothing, and goes away once the time is good. H:MM and HHMM are times too.
clear_notifications
open_popout
type_time 25:99
within text_shown 'Type a time as HH:MM'
vekrona-dev key ret
vekrona-dev click-text '^Start$'
within caffeine_ready
status_off || die "a time the field cannot read must not start a session, but status says: $(status)"
vekrona-dev key ctrl-a
vekrona-dev type 9:30
within text_shown 'That time is past'
vekrona-dev key ret
within caffeine_ready
status_off || die "a past time must not start a session, but status says: $(status)"
vekrona-dev key ctrl-a
vekrona-dev type 1430
within text_absent 'past|Type a time as'
vekrona-dev key ret
within status_matches '^kind=until end=[0-9]+ preset=- target=14:30$'
log "ok: 25:99 and a past 9:30 show why and start nothing; 1430 is read as 14:30 and starts"
vekrona-dev sh vekrona-caffeine off
within status_off
assert_unit_never_failed

# 4. Download: the real file Firefox is still writing is a random name beside an empty placeholder with the real name.
downloads="$(downloads_dir)"
vekrona-dev sh bash -c ': >"$1/$2"; : >"$1/$3"' _ "$downloads" "$DOWNLOAD_LABEL" "$PARTIAL_NAME"
# ping prints a line every 2 s, so the partial file keeps growing, as a download does.
vekrona-dev spawn "$WRITER_LOG" -- bash -c 'exec stdbuf -oL ping -i 2 127.0.0.1 >>"$1/$2"' _ "$downloads" "$PARTIAL_NAME"
clear_notifications
open_popout
vekrona-dev click-text '^download$'
within text_shown 'x\.iso'
log "ok: the download list names the partial file after the empty $DOWNLOAD_LABEL"

vekrona-dev click-text 'x\.iso'
within status_matches "^kind=file end=- preset=- target=$DOWNLOAD_LABEL\$"
log "ok: picking $DOWNLOAD_LABEL waits for the partial file"

flush_toasts
ended_before="$(ended_toasts)"
vekrona-dev sh mv "$downloads/$PARTIAL_NAME" "$downloads/$DOWNLOAD_LABEL"
within status_off
assert_unit_never_failed
flush_toasts
[[ "$(ended_toasts)" == "$((ended_before + 1))" ]] || die "the finished download must toast its end once"
log "ok: renaming the partial file over $DOWNLOAD_LABEL ends the session, with no unit failure"

# 5. Process: closing the window ends the wait.
vekrona-dev spawn "$WINDOW_LOG" -- foot -a "$WINDOW_APP_ID" sleep infinity
within vekrona-dev sh bash -c 'swaymsg -t get_tree | jq -e --arg id "$1" "[.. | objects | select(.app_id? == \$id)] | length == 1" >/dev/null' _ "$WINDOW_APP_ID"
clear_notifications
open_popout
vekrona-dev click-text '^process$'
within text_shown "$WINDOW_APP_ID"
vekrona-dev click-text "$WINDOW_APP_ID"
within status_matches "^kind=pid end=- preset=- target=$WINDOW_APP_ID\$"
log "ok: picking the foot window waits for its process"

vekrona-dev sh swaymsg "[app_id=$WINDOW_APP_ID] kill" >/dev/null
within status_off
assert_unit_never_failed
log "ok: closing the window ends the session, with no unit failure"

# 6. Input the CLI cannot wait for is refused with a message, and the session in place is not touched.
REFUSED_EXIT=2
refused() {
  local out rc=0
  out="$(vekrona-dev sh vekrona-caffeine "$@" 2>&1)" || rc=$?
  ((rc == REFUSED_EXIT)) || die "vekrona-caffeine $* must exit $REFUSED_EXIT, but it exited $rc and printed: $out"
  [[ "$out" == *"vekrona-caffeine: "* ]] || die "vekrona-caffeine $* must explain the refusal, but it printed: $out"
}
refuses_everything() {
  local expected="$1" past
  past="$(vekrona-dev sh date -d '1 hour ago' '+%F %H:%M')"
  refused pid 0 nobody
  refused pid 999999 nobody
  refused file /nonexistent nobody
  refused until "$past"
  refused until lizard
  refused for lizard
  refused for 0
  [[ "$(status | sed -E 's/ end=[0-9]+//')" == "$expected" ]] || die "after the refused commands the status is '$(status)', but it must stay '$expected'"
}
refuses_everything off
log "ok: pid 0, pid 999999, file /nonexistent, a past until, until lizard, for lizard and for 0 are refused and leave the status off"

vekrona-dev sh vekrona-caffeine for 3h
refuses_everything 'kind=for preset=3h target=3h'
log "ok: the same input leaves a running session as it was"

vekrona-dev sh vekrona-caffeine off
within status_off

# 7. A pick the CLI refuses, here a download that vanished while the list was open, is explained in a notification.
vekrona-dev sh bash -c ': >"$1/gone.iso"; : >"$1/Gone.part"' _ "$downloads"
clear_notifications
open_popout
vekrona-dev click-text '^download$'
within text_shown 'gone\.iso'
vekrona-dev sh rm "$downloads/Gone.part"
shell_errors_before="$(shell_errors)"
vekrona-dev click-text 'gone\.iso'
within monitor_has 'no such file'
[[ "$(shell_errors)" == "$shell_errors_before" ]] || die "a refused pick is the user's doing: it must not be logged as an error the error pipeline records"
status_off || die "a refused pick must leave the status off, but it says: $(status)"
log "ok: picking a download that vanished toasts the CLI's reason, logs no error and starts nothing"

# 8. The end timer stops a session by itself, and that is no failure.
vekrona-dev sh vekrona-caffeine for "$SHORT_SESSION"
within status_off
assert_unit_never_failed
log "ok: a $SHORT_SESSION session ends by its timer, with no unit failure"

# 9. A partial file nobody writes to ends the session after the idle limit, with a toast that says so.
vekrona-dev sh bash -c ': >"$1/Stall.part"' _ "$downloads"
vekrona-dev sh vekrona-caffeine file "$downloads/Stall.part" stall.iso
status_matches '^kind=file end=- preset=- target=stall\.iso$' || die "the stalled file's session did not start: $(status)"
vekrona-dev until --timeout "$((FILE_IDLE_SEC + STEP_TIMEOUT_SEC))" -- status_off
assert_unit_never_failed
flush_toasts
vekrona-dev run grep -qF "Download stalled for $FILE_IDLE_SEC s: stall.iso" "$MONITOR_LOG" || die "a stalled download must toast why its session ended"
log "ok: a partial file with no write for ${FILE_IDLE_SEC}s ends the session with a stalled toast, and no unit failure"

# 10. A step in the until time carries into the day: from 22:10 the default is 23:00 today, and from a typed 23:58 Up makes it 00:03 tomorrow.
vekrona-dev run sudo date -s "2026-10-16 22:10:00" >/dev/null
clear_notifications
open_popout
within text_shown 'Today'
type_time 23:58
vekrona-dev key up
within text_shown 'Tomorrow'
vekrona-dev click-text '^Start$'
within status_matches '^kind=until end=[0-9]+ preset=- target=Sat 00:03$'
log "ok: Up from a typed 23:58 shows Tomorrow 00:03, and Start is enabled for it"
vekrona-dev sh vekrona-caffeine off
within status_off

# 10b. A menu left open past midnight counts its days from the new day: from 23:50 the default is 00:00 tomorrow, and once the clock
# passes midnight the same choice is today, and past.
vekrona-dev run sudo date -s "2026-10-16 23:50:00" >/dev/null
clear_notifications
open_popout
within text_shown 'Tomorrow'
vekrona-dev run sudo date -s "2026-10-17 00:05:00" >/dev/null
within text_shown 'Today'
within text_shown 'That time is past'
log "ok: a menu left open past midnight shows today for the day that was tomorrow"
vekrona-dev click "$PILL_X" "$PILL_Y"
within text_absent 'Stay awake for'

# 11. The shell may be loading when a session starts or ends: that is not a failure, and any other answer to the refresh is.
with_fake_qs() {
  local message="$1"
  shift
  vekrona-dev sh bash -c 'dir="$(mktemp -d)"; printf "#!/bin/sh\necho \"%s\"\n" "$1" >"$dir/qs"; chmod +x "$dir/qs"; shift; PATH="$dir:$PATH" "$@"; rc=$?; rm -rf "$dir"; exit "$rc"' _ "$message" "$@"
}
with_fake_qs "Not ready to accept queries yet." vekrona-caffeine for 1h
status_matches '^kind=for end=[0-9]+ preset=1h target=1h$' || die "a shell that is not ready yet must not fail the start: $(status)"
vekrona-dev sh vekrona-caffeine off
within status_off
rc=0
with_fake_qs "Target not found." vekrona-caffeine for 1h 2>/dev/null || rc=$?
((rc == 1)) || die "an answer other than an empty one or a not-ready shell must fail the refresh with the unexpected-failure status 1, but the command exited $rc"
vekrona-dev sh vekrona-caffeine off
within status_off
log "ok: a shell that is not ready is no failure; any other refresh answer fails the command"
