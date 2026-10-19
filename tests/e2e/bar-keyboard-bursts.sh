#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
UNPLUG_CYCLES=3
# The first event starts the query that is held; the others arrive while it is held.
EVENTS_DURING_HELD_QUERY=4
# Workspaces nobody uses, which the burst of workspace events visits.
SCRATCH_WORKSPACE_BASE=20
BURST_END=e2e-burst-end
# A guest swaymsg earlier on PATH than the real one. For the shell's two queries (get_inputs and get_tree) it counts every call
# (KIND.queries), and, while the fifo KIND.hold exists, holds each call until the test writes a verdict into it: "ok" runs the real
# query (KIND.passed counts those), "fail" ends like a query whose IPC connection Sway dropped (KIND.failed). Without a fifo, the
# file KIND.fail makes every call fail.
SHIM_DIR=/tmp/e2e-keyboard-ipc
EVENTS_FILE=/tmp/e2e-keyboard-ipc-events
export SHIM_DIR EVENTS_FILE BURST_END

# How many lines the shim wrote to $SHIM_DIR/$1.$2.
shim_lines() { vekrona-dev run bash -c 'wc -l <"$1/$2.$3"' _ "$SHIM_DIR" "$1" "$2"; }
shim_lines_are() { [[ "$(shim_lines "$1" "$2")" == "$3" ]]; }
shim_lines_reach() { (($(shim_lines "$1" "$2") >= $3)); }
# Whether the event watcher has seen Sway announce the end of the burst: Sway sends its events to a client in order, so every event
# before the tick has been sent by then.
burst_announced() { vekrona-dev run grep -q "$BURST_END" "$EVENTS_FILE"; }
watching() { vekrona-dev run grep -q '"subscribed"' "$EVENTS_FILE"; }
# Every failed query after the first of a run of failures is logged once, the first not at all, and nothing is logged as Keyboard.
failures_logged_once() {
  (($(shell_errors) - ERRORS_BEFORE == $(shim_lines "$KIND" failed) - 1)) && [[ "$(keyboard_errors)" == "$KEYBOARD_ERRORS_BEFORE" ]]
}
export -f shim_lines shim_lines_are shim_lines_reach burst_announced watching failures_logged_once

switch_layout() { vekrona-dev sh swaymsg input type:keyboard xkb_switch_layout next; }
visit_scratch_workspace() { vekrona-dev sh swaymsg workspace number "$((SCRATCH_WORKSPACE_BASE + $1))"; }

arm_shim() {
  vekrona-dev run bash -c 'rm -rf "$1" && mkdir -p "$1" "$HOME/.local/bin" && cat >"$HOME/.local/bin/swaymsg" && chmod +x "$HOME/.local/bin/swaymsg"' _ "$SHIM_DIR" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
dir=/tmp/e2e-keyboard-ipc
case "$*" in
  "-t get_inputs --raw") kind=get_inputs ;;
  "-t get_tree") kind=get_tree ;;
  *) exec /usr/bin/swaymsg "$@" ;;
esac
echo >>"$dir/$kind.queries"
if [[ -e $dir/$kind.hang ]]; then
  echo >>"$dir/$kind.hung"
  exec sleep infinity
fi
verdict=ok
if [[ -p $dir/$kind.hold ]]; then
  echo >>"$dir/$kind.held"
  read -r verdict <"$dir/$kind.hold"
elif [[ -e $dir/$kind.fail ]]; then
  verdict=fail
fi
if [[ $verdict == fail ]]; then
  echo >>"$dir/$kind.failed"
  echo "00:00:03.040 [ERROR] [common/ipc-client.c:86] Unable to receive IPC response" >&2
  exit 1
fi
status=0
/usr/bin/swaymsg "$@" || status=$?
echo >>"$dir/$kind.passed"
exit "$status"
SHIM
}
# pkill runs before the rm: a bash whose command line names the shim would match its own pattern and kill itself.
disarm_shim() {
  vekrona-dev run pkill -f '[.]local/bin/swaymsg' || [[ $? -eq 1 ]]
  vekrona-dev run bash -c 'rm -rf "$1" "$HOME/.local/bin/swaymsg"' _ "$SHIM_DIR"
}
# A new run of the kind's queries: empty counters, no fifo and no failing or hanging flag.
reset_kind() {
  vekrona-dev run bash -c 'cd "$1" && rm -f "$2.hold" "$2.fail" "$2.hang" && : >"$2.queries" && : >"$2.held" && : >"$2.failed" && : >"$2.passed" && : >"$2.hung"' _ "$SHIM_DIR" "$1"
}
hold_queries() { vekrona-dev run mkfifo "$SHIM_DIR/$1.hold"; }
# A query that started in the instant before the fifo went waits for a verdict nobody gives: it is killed, and the shell asks
# again, now unheld, which is the one more answer that is waited for.
release_hold() {
  local kind=$1 passed
  vekrona-dev run rm -f "$SHIM_DIR/$kind.hold"
  passed="$(shim_lines "$kind" passed)"
  if vekrona-dev run pkill -f "[.]local/bin/swaymsg -t $kind"; then
    vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" passed "$((passed + 1))"
  fi
}
# Writing into the fifo waits for a held query to read it, and gives the verdict to exactly that query.
verdict() { vekrona-dev run bash -c 'echo "$2" >"$1/$3.hold"' _ "$SHIM_DIR" "$2" "$1"; }

watch_events() {
  vekrona-dev events "$EVENTS_FILE" "$@" tick
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watching
}
stop_watching() { vekrona-dev run bash -c 'pkill -f "[s]way-events.py" || [[ $? -eq 1 ]]; rm -f "$1"' _ "$EVENTS_FILE"; }

# A query that ended in failure leaves the shell expecting the next one to fail too, so the next failure would be reported. Two
# workspace events make the shell ask again, now without the shim, and a successful answer clears that.
refresh_workspace_query() {
  visit_scratch_workspace 0
  vekrona-dev sh swaymsg workspace number "$HOME_WORKSPACE"
}

# The shim goes first: left armed, it would make every later scenario's sway queries hang or fail.
restore() {
  run_cleanups disarm_shim plug_keyboards stop_watching 'set_layouts us' refresh_workspace_query
}

# Holds the shell's first query of KIND, sends more events while it is held, and then fails it the way Sway does when it drops the
# connection of a query that was running while the system slept. The events must cost exactly one more query, which sees the
# state the whole burst left, and no error. Arguments: KIND, the sway event type the shell follows, and the function that
# causes one event per call (given the burst's index).
drop_during_burst() {
  local kind=$1 event_type=$2 cause=$3 i
  reset_kind "$kind"
  hold_queries "$kind"
  watch_events "$event_type"
  "$cause" 0
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" held 1
  for ((i = 1; i <= EVENTS_DURING_HELD_QUERY; i++)); do
    "$cause" "$i"
  done
  vekrona-dev sh swaymsg -t send_tick "$BURST_END"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- burst_announced
  verdict "$kind" fail
  # The one follow-up is held in turn: the query that dropped has ended, and no other has started.
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" held 2
  verdict "$kind" ok
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" passed 1
  release_hold "$kind"
  stop_watching
  shim_lines_are "$kind" queries 2 || die "a burst of $((EVENTS_DURING_HELD_QUERY + 1)) $event_type events behind a running $kind query must cost exactly one more query, but the shell ran $(shim_lines "$kind" queries) in all"
}

# Sway drops the one running query and nothing else happens: the shell asks again by itself, and nothing is logged.
drop_without_a_following_event() {
  local kind=$1 event_type=$2 cause=$3
  reset_kind "$kind"
  hold_queries "$kind"
  watch_events "$event_type"
  "$cause" 0
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" held 1
  verdict "$kind" fail
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" held 2
  verdict "$kind" ok
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" passed 1
  release_hold "$kind"
  stop_watching
  shim_lines_are "$kind" queries 2 || die "a $kind query that Sway dropped, with no event after it, must be asked once more and no more, but the shell ran $(shim_lines "$kind" queries) in all"
}

# A query that never answers is stopped after its limit and logged once, and the next event asks again.
timed_out_logged() { shell_log_count 'timed out after'; }
timeout_logged() { (($(timed_out_logged) == TIMEOUTS_BEFORE + 1)); }
export -f timed_out_logged timeout_logged
hung_query_is_stopped() {
  local kind=$1 cause=$2 timeouts_before
  timeouts_before="$(timed_out_logged)"
  reset_kind "$kind"
  vekrona-dev run touch "$SHIM_DIR/$kind.hang"
  # An index nobody visited last: a workspace that is already current sends no event.
  "$cause" 5
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" hung 1
  TIMEOUTS_BEFORE=$timeouts_before vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- timeout_logged
  vekrona-dev run rm -f "$SHIM_DIR/$kind.hang"
  "$cause" 6
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" passed 1
}

# Every query fails, as it does while Sway is gone. The first failure is a connection Sway dropped, not an error to report; each
# later one is logged once. A query held at the end proves every earlier one has ended, and so has been logged.
failures_are_logged_once() {
  local kind=$1 cause=$2
  reset_kind "$kind"
  vekrona-dev run touch "$SHIM_DIR/$kind.fail"
  "$cause" 0
  "$cause" 1
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" failed 2
  hold_queries "$kind"
  "$cause" 2
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" held 1
  KIND=$kind vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- failures_logged_once
  vekrona-dev run rm -f "$SHIM_DIR/$kind.fail"
  verdict "$kind" ok
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shim_lines_reach "$kind" passed 1
  release_hold "$kind"
}

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
HOME_WORKSPACE="$(vekrona-dev sh swaymsg -t get_workspaces | jq -r '.[] | select(.focused) | .num')"
trap restore EXIT
set_layouts us,ua
# Sway keeps the active layout while the list stays the same, so an earlier run's choice would show UA, not EN.
vekrona-dev sh swaymsg input type:keyboard xkb_switch_layout 0
refresh_workspace_query

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- text_shown "EN"
read -r PILL_X y <<<"$(vekrona-dev see find "EN")"
[[ -n "${PILL_X:-}" && -n "${y:-}" ]] || die "the bar must show the layout code EN once the keymap has two layouts"
export PILL_X

ERRORS_BEFORE="$(shell_errors)"
KEYBOARD_ERRORS_BEFORE="$(keyboard_errors)"
export ERRORS_BEFORE KEYBOARD_ERRORS_BEFORE
for ((cycle = 1; cycle <= UNPLUG_CYCLES; cycle++)); do
  unplug_keyboards
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_keyboards
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_hidden "EN"
  plug_keyboards
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "EN"
done
[[ "$(shell_errors)" == "$ERRORS_BEFORE" ]] || die "a keyboard that is unplugged and plugged $UNPLUG_CYCLES times, as a USB KVM switch does, logged a failed command"
[[ "$(keyboard_errors)" == "$KEYBOARD_ERRORS_BEFORE" ]] || die "a keyboard that is unplugged and plugged $UNPLUG_CYCLES times logged a Keyboard error"
log "ok: $UNPLUG_CYCLES unplug and plug cycles of the keyboard log no error, and the bar shows EN again after each"

arm_shim

drop_during_burst get_inputs input switch_layout
# The number of switches is odd, so the layout is UA once the shell has read the state the whole burst left behind.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- code_shown "UA"
[[ "$(shell_errors)" == "$ERRORS_BEFORE" ]] || die "a keyboard query that Sway dropped while it was running logged a failed command"
[[ "$(keyboard_errors)" == "$KEYBOARD_ERRORS_BEFORE" ]] || die "a keyboard query that Sway dropped while it was running logged a Keyboard error"
log "ok: a burst of input events behind a query that Sway drops costs one more query, logs nothing, and the bar follows the final layout"

drop_during_burst get_tree workspace visit_scratch_workspace
[[ "$(shell_errors)" == "$ERRORS_BEFORE" ]] || die "a workspace query that Sway dropped while it was running logged a failed command"
log "ok: a burst of workspace events behind a query that Sway drops costs one more query and logs nothing"

failures_are_logged_once get_inputs switch_layout
log "ok: keyboard queries that keep failing log one line each, except the first"

ERRORS_BEFORE="$(shell_errors)"
failures_are_logged_once get_tree visit_scratch_workspace
log "ok: workspace queries that keep failing log one line each, except the first"

drop_without_a_following_event get_inputs input switch_layout
drop_without_a_following_event get_tree workspace visit_scratch_workspace
log "ok: a query that Sway dropped with nothing after it is asked once more, and nothing is logged"

hung_query_is_stopped get_tree visit_scratch_workspace
log "ok: a query that never answers is stopped and logged once, and the next event asks again"
