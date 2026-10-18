#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
NO_OUTPUT_REGEX="[Nn]o ?output"

no_output_shown() { text_shown "$NO_OUTPUT_REGEX"; }
export -f no_output_shown
export NO_OUTPUT_REGEX

restore_wireplumber() { vekrona-dev run systemctl --user start wireplumber.service && restart_shell; }

vekrona-dev session
clear_notifications
vekrona-dev move 600 500
since="$(vekrona-dev run date +%s)"

# WirePlumber owns the "default" metadata the shell reads the default sink from. A shell that starts without it has no
# default sink, the state it is in while the audio interface behind a KVM is away and WirePlumber has nothing to pick.
trap restore_wireplumber EXIT
vekrona-dev run systemctl --user stop wireplumber.service
restart_shell
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_output_shown
log "ok: the bar says there is no output"

for command in "audio increment 5" "audio decrement 5" "audio mute"; do
  # shellcheck disable=SC2086 # the words are the IPC call's arguments
  vekrona-dev sh qs -c vekrona-shell ipc call $command
done
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_output_shown
log "ok: the volume and mute commands without an output leave the shell saying so"

shell_errors_during="$(shell_log_since_matching "$since" ERROR)"
[[ -z "$shell_errors_during" ]] || die "vekrona-shell logged errors for the volume keys without an output: $shell_errors_during"
log "ok: the shell logged no error"
