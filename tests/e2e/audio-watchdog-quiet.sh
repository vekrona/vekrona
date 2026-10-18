#!/usr/bin/env bash
# The audio watchdog restarts WirePlumber only for a real wedge: not for a PipeWire restart, not for a card somebody turned off.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# The watchdog waits this long before it acts, and the scenario watches twice as long.
WATCH_SEC=15
RESTART_RECORD_REGEX="WirePlumber stopped reacting to devices and was restarted"

watchdog_active() { [[ "$(vekrona-dev run systemctl --user is-active vekrona-audio-watchdog.service)" == active ]]; }
wireplumber_pid() { vekrona-dev run systemctl --user show --property MainPID --value wireplumber.service; }
wireplumber_restarted() { [[ "$(wireplumber_pid)" != "$WIREPLUMBER_PID" ]]; }
watchdog_cpu_ns() { vekrona-dev run systemctl --user show --property CPUUsageNSec --value vekrona-audio-watchdog.service; }
watchdog_log() { vekrona-dev run journalctl --user -u vekrona-audio-watchdog.service --since "@$1" --no-pager; }
card_stored_off() { vekrona-dev run bash -c 'grep -q "USB_Audio.*=off" "$HOME/.local/state/wireplumber/default-profile"'; }
export -f watchdog_active wireplumber_pid wireplumber_restarted card_stored_off
export WIREPLUMBER_PID

# The card goes back to its usable profile, so that the next scenario does not meet the profile this one stored as off.
restore_usb_card_profile() {
  usb_card_listed || return 0
  vekrona-dev run bash -c 'wpctl set-profile "$1" 1' _ "$(usb_card_id)"
}
cleanup() { run_cleanups restore_usb_card_profile audio_teardown; }

restart_records() { vekrona-dev run vekrona-error list --all | grep -c "$RESTART_RECORD_REGEX" || [[ $? -eq 1 ]]; }

vekrona-dev session
watchdog_active || die "vekrona-audio-watchdog.service is not running"
restarts_before="$(restart_records)"

# A PipeWire restart ends the watchdog's monitor: systemd stops the watchdog with PipeWire and starts it again, with no
# failure to toast or record.
since="$(vekrona-dev run date +%s)"
vekrona-dev run systemctl --user restart pipewire.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- watchdog_active
# The log is read whole: grep -q ends early, and under pipefail the writer's SIGPIPE would make this negation pass whatever was logged.
watchdog_report="$(watchdog_log "$since")"
! grep -q 'PipeWire is gone' <<<"$watchdog_report" || die "the watchdog died of the PipeWire restart: $watchdog_report"
[[ "$(vekrona-dev run systemctl --user show --property NRestarts --value vekrona-audio-watchdog.service)" == 0 ]] \
  || die "the watchdog had to be restarted by its own failure after a PipeWire restart"
log "ok: a PipeWire restart is not a failure of the watchdog"

# The null sink is PipeWire's, so it is loaded after the restart.
audio_setup
trap cleanup EXIT

# CPU time the watchdog spends while the scenario watches WATCH_SEC for a restart of WirePlumber, which must not come.
# Prints the nanoseconds; $1 names the state being watched, for the failure message.
watch_for_restart_cpu_ns() {
  local before after
  before="$(watchdog_cpu_ns)"
  if vekrona-dev until --timeout "$WATCH_SEC" -- wireplumber_restarted 2>/dev/null; then
    die "the watchdog restarted WirePlumber $1"
  fi
  after="$(watchdog_cpu_ns)"
  echo "$((after - before))"
}

# The watchdog's CPU time over a quiet graph, as this host measures it now: a loaded machine makes every wake-up cost more, so the
# idle check below is relative to this and not to a fixed number.
audio_stream_start
audio_expect "$FALLBACK_SINK" "the stream did not start on the only card"
WIREPLUMBER_PID="$(wireplumber_pid)"
export WIREPLUMBER_PID
baseline_ns="$(watch_for_restart_cpu_ns "on a quiet graph")"

# A card turned off by hand (WirePlumber stores that as the card's profile) is a choice, not a wedge.
usb_audio_add
audio_expect "$USB_AUDIO_SINK" "the USB card did not become the default"
vekrona-dev run bash -c 'wpctl set-profile "$1" 0' _ "$(usb_card_id)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- card_stored_off
WIREPLUMBER_PID="$(wireplumber_pid)"
export WIREPLUMBER_PID
used_ns="$(watch_for_restart_cpu_ns "for a card that was turned off on purpose")"
[[ "$(restart_records)" == "$restarts_before" ]] || die "a restart was recorded for a card that was turned off on purpose"
log "ok: a card turned off by hand is left alone"

# Its own snapshots make clients come and go in PipeWire, and those must not wake it again: an idle graph costs nothing.
# Quiet means a twentieth of a CPU at most, or, on a machine where even the baseline costs more, three times the baseline; a baseline
# that is itself above a quarter of a CPU says the watchdog spins whatever the graph does.
quiet_ns=$((WATCH_SEC * 1000000000 / 20))
((baseline_ns < WATCH_SEC * 1000000000 / 4)) \
  || die "the watchdog used $((baseline_ns / 1000000)) ms of CPU in $WATCH_SEC s of a graph with nothing going on: it spins"
limit_ns=$((baseline_ns * 3 > quiet_ns ? baseline_ns * 3 : quiet_ns))
((used_ns < limit_ns)) \
  || die "the watchdog used $((used_ns / 1000000)) ms of CPU in $WATCH_SEC s of a quiet graph ($((baseline_ns / 1000000)) ms with nothing going on): it wakes itself"
log "ok: the watchdog is idle while the graph is"
