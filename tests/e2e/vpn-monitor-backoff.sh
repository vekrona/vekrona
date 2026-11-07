#!/usr/bin/env bash
# The shell starts `nmcli monitor` again when it dies, after a wait that doubles with every death (1 s, 2 s, 4 s, ...). A monitor that
# then ran longer than the wait it was started after is healthy again, so the next death starts over at 1 s. Without that, the wait
# of a monitor that dies once a day would creep up to a minute and stay there (it started over only at a line of output, which a
# quiet network never gives). The scenario kills the monitor three times, so that the fourth was started after 4 s and the wait after
# its death would be 8 s; it lets the fourth run past 4 s, kills it before 8 s and expects "1 s". Comparing with the next wait (8 s)
# instead of the wait it was started after (4 s) gave "8 s".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
# The fourth monitor is started after 4 s: one that ran for more than this many seconds ran longer than its wait. The scenario kills
# it as soon as it has (before the 8 s that the next wait would be).
export LONGER_THAN_THE_WAIT_SEC=4

# The monitor of the shell: `stdbuf -oL nmcli monitor` execs into nmcli, so its command line is "nmcli monitor".
monitor_running() { vekrona-dev run pgrep -x -f 'nmcli monitor' >/dev/null; }
monitor_ran_longer_than_the_wait() {
  local seconds
  seconds="$(vekrona-dev run ps -o etimes= -p "$(vekrona-dev run pgrep -x -f 'nmcli monitor')")" || return 1
  ((seconds > LONGER_THAN_THE_WAIT_SEC))
}
# How many times the shell logged that the monitor stopped with a wait of $1 seconds before the next try.
stops_with_wait() { shell_log_count "nmcli monitor stopped: .*next try in $1 s"; }
stop_logged_with_wait() { [[ "$(stops_with_wait "$1")" -gt "$2" ]]; }
export -f monitor_running monitor_ran_longer_than_the_wait stops_with_wait stop_logged_with_wait

# Kills the monitor, waits until the shell has logged its death (a dying process still shows to pgrep) and then until the shell has
# started a new one.
kill_monitor_and_wait_for_the_next() {
  local before
  before="$(stops_with_wait '[0-9]+')"
  vekrona-dev run pkill -x -f 'nmcli monitor'
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- stop_logged_with_wait '[0-9]+' "$before" || die "the shell must notice that the monitor died"
  vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- monitor_running || die "the monitor must be started again"
}

vekrona-dev session
restart_shell
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- monitor_running || die "the shell must run nmcli monitor"

# Three quick deaths: the fourth monitor is started after 4 s, and the wait after its death would be 8 s.
kill_monitor_and_wait_for_the_next
kill_monitor_and_wait_for_the_next
kill_monitor_and_wait_for_the_next
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- monitor_ran_longer_than_the_wait || die "the monitor must stay up"

before="$(stops_with_wait 1)"
vekrona-dev run pkill -x -f 'nmcli monitor'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- stop_logged_with_wait 1 "$before" || die "a monitor that ran longer than its wait must start the wait over at 1 s"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- monitor_running || die "the monitor must be started again"
log "ok: a monitor that ran longer than its wait starts the wait over"
