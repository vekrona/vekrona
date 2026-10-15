#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="$ROOT/tests/stages/$(basename "${BASH_SOURCE[0]}")"

# A test that sources lib/common.sh directly gets the default reporter, which writes the user's real error store.
direct="$(grep -rlE 'source .*lib/common\.sh' "$ROOT/tests" --include='*.sh' | grep -vxe "$ROOT/tests/lib.sh" -e "$SELF" || true)"
[[ -z "$direct" ]] || { echo "FAIL: source tests/lib.sh, not lib/common.sh, in: $direct" >&2; exit 1; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The bus of the desktop session that runs this test (a stand-in path): tests/lib.sh must cut every test process off it.
desktop_bus="unix:path=$scratch/desktop-session-bus"
export DBUS_SESSION_BUS_ADDRESS="$desktop_bus"
source "$ROOT/tests/lib.sh"

# Stands in for the real reporter: it records the call where this test can see it. Exported by tests/lib.sh to
# every process, it is what die() reaches, so a die() inside a test can never reach the journal.
[[ "$VEKRONA_ERROR_REPORTER" != "$VEKRONA_ROOT/bin/vekrona-error" ]] \
  || die "tests/lib.sh left die() reporting through the real bin/vekrona-error"

printf '#!/bin/sh\necho "$*" >> "%s/reported"\n' "$scratch" > "$scratch/reporter"
chmod +x "$scratch/reporter"

status=0
bash -c 'source "$1/tests/lib.sh"; VEKRONA_ERROR_REPORTER="$2"; die "expected failure"' _ "$ROOT" "$scratch/reporter" 2>/dev/null || status=$?
[[ "$status" -eq 1 ]] || die "die() must exit 1, got $status"
grep -q -- '--title expected failure' "$scratch/reported" || die "die() must report through \$VEKRONA_ERROR_REPORTER: $(cat "$scratch/reported" 2>&1)"
log "ok: die() reports through the replaceable reporter"

# A child process that sources lib/common.sh (a stage, a bin tool) inherits the stub, not the default.
inherited="$(bash -c 'source "$1/lib/common.sh"; printf %s "$VEKRONA_ERROR_REPORTER"' _ "$ROOT")"
[[ "$inherited" == "$VEKRONA_ERROR_REPORTER" && "$inherited" != "$ROOT/bin/vekrona-error" ]] \
  || die "child processes must inherit the test reporter, got: $inherited"
log "ok: child processes inherit the test reporter"

# A direct `vekrona-error report` from a test must not reach the real journal: it fails loudly instead.
status=0
"$ROOT/bin/vekrona-error" report --title "must not be recorded" >/dev/null 2>"$scratch/report-err" || status=$?
[[ "$status" -ne 0 ]] || die "vekrona-error report succeeded inside a test: it reached a real journal"
grep -q 'failed to write to the journal' "$scratch/report-err" || die "the failed report did not surface the connection error: $(cat "$scratch/report-err")"
log "ok: a direct vekrona-error report cannot reach the real journal"

# die() in a bin tool also shows a toast through notify-send. A failing direct report is such a die(), and it must never
# reach the desktop's notification daemon: notify-send has to find the bus unreachable.
printf '#!/bin/sh\necho "$DBUS_SESSION_BUS_ADDRESS" >> "%s/notify-bus"\n' "$scratch" > "$scratch/notify-send"
chmod +x "$scratch/notify-send"
PATH="$scratch:$PATH" "$ROOT/bin/vekrona-error" report --title "must not be shown" >/dev/null 2>&1 || true
[[ -s "$scratch/notify-bus" ]] || die "the failed report did not try to show a notification, so this check proves nothing"
[[ "$(cat "$scratch/notify-bus")" != "$desktop_bus" ]] || die "a test's die() toast reached the desktop session bus"
log "ok: a die() inside a test cannot show a toast on the desktop"
