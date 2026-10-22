#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

skip_as_root "root has no desktop to toast on"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
logs="$scratch/logs"
mkdir -p "$stubs"
export SCRATCH="$scratch"

write_fake "$stubs/reporter" <<'F'
#!/bin/sh
echo "$*" >> "$SCRATCH/logs/reported"
[ "${REPORT_FAIL:-}" != 1 ]
F
write_fake "$stubs/notify-send" <<'F'
#!/bin/sh
echo "$*" >> "$SCRATCH/logs/notified"
[ "${NOTIFY_FAIL:-}" != 1 ]
F

# Runs a function of lib/common.sh (through tests/lib.sh) in a fresh shell with the stubs in front, and leaves the exit
# status in $rc.
run_common() {
  rm -rf "$logs"
  mkdir -p "$logs"
  rc=0
  PATH="$stubs:$PATH" \
    bash -c 'source "$1/tests/lib.sh"; VEKRONA_ERROR_REPORTER="$2"; shift 2; "$@"; echo went-on' _ "$ROOT" "$stubs/reporter" "$@" \
    >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
}
count() { if [[ -e "$logs/$1" ]]; then wc -l < "$logs/$1"; else echo 0; fi; }

run_common die "the disk is full"
[[ "$rc" == 1 ]] || die "die must exit 1, got $rc"
[[ "$(count reported)" == 1 ]] || die "die must report exactly once: $(cat "$logs/reported" 2>&1)"
grep -q -- '--title the disk is full' "$logs/reported" || die "the report must carry the message: $(cat "$logs/reported")"
[[ "$(count notified)" == 0 ]] || die "a reported failure is shown by the robot, not toasted here: $(cat "$logs/notified")"
log "ok: a die() makes one report and no toast of its own"

REPORT_FAIL=1 run_common die "the disk is full"
[[ "$rc" == 1 ]] || die "die must exit 1 when the report fails, got $rc"
grep -q 'failed to report' "$scratch/stderr" || die "a failed report must be named: $(cat "$scratch/stderr")"
[[ "$(count notified)" == 1 ]] || die "a failure that was not recorded must be toasted once: $(cat "$logs/notified" 2>&1)"
grep -q -- '-u critical .* the disk is full' "$logs/notified" || die "the toast must be critical and carry the message: $(cat "$logs/notified")"
log "ok: a failure that cannot be reported is toasted once"

REPORT_FAIL=1 NOTIFY_FAIL=1 run_common die "the disk is full"
[[ "$rc" == 1 ]] || die "die must exit 1 when nothing can be shown, got $rc"
grep -q 'failed to show this error as a notification' "$scratch/stderr" || die "a failed toast must be named: $(cat "$scratch/stderr")"
log "ok: a failure that can be neither reported nor toasted still ends the command and says why"

run_common report_failure "cleanup failed"
[[ "$rc" == 0 ]] || die "report_failure must return, got $rc"
grep -qx went-on "$scratch/stdout" || die "report_failure must let the caller go on"
[[ "$(count reported)" == 1 && "$(count notified)" == 0 ]] || die "report_failure must report once and not toast"
log "ok: report_failure reports like die() and returns"
