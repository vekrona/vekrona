#!/usr/bin/env bash
# A brightness step that is not a positive number of percent is refused with a logged error, before brightnessctl could read it
# as an option or as no change.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# Only what the shell logged since the call counts, and the pipe is read in the guest: a grep that quits at its first match makes a
# writer on the host side of the pipe fail with SIGPIPE, which `pipefail` reads as no match.
step_refused() {
  vekrona-dev sh bash -c 'journalctl --user --no-pager -o cat -t vekrona-shell --after-cursor "$1" | grep -q "brightness: the step must be a positive number"' _ "$JOURNAL_CURSOR"
}
export -f step_refused

vekrona-dev session
errors_before="$(shell_errors)"
JOURNAL_CURSOR="$(vekrona-dev sh journalctl --user -n 0 --show-cursor | sed -n 's/^-- cursor: //p')"
[[ -n "$JOURNAL_CURSOR" ]] || die "cannot read the user journal's cursor"
export JOURNAL_CURSOR
vekrona-dev sh qs -c vekrona-shell ipc call brightness increment 0 >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- step_refused || die "a brightness step of 0 must be refused with a logged error"
[[ "$(shell_errors)" == "$errors_before" ]] || die "a refused step must not start brightnessctl, but a command failed"
log "ok: a brightness step of 0 is refused before any command runs"
