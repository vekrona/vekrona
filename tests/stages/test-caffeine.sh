#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# The tool runs from a path with a space and a % in it: systemd reads both in an Exec line.
tree="$scratch/a b%h"
stubs="$scratch/stubs"
mkdir -p "$tree/bin" "$tree/lib" "$stubs" "$scratch/run"
cp "$ROOT/bin/vekrona-caffeine" "$tree/bin/"
cp "$ROOT/lib/common.sh" "$tree/lib/"
tool="$tree/bin/vekrona-caffeine"
export XDG_RUNTIME_DIR="$scratch/run" SCRATCH="$scratch"

stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }
stub systemd-run 'printf "%s\n" "$*" >> "$SCRATCH/systemd-run"'
stub systemctl '[[ "$*" != *"show -p LoadState"* ]] || echo not-found'
stub notify-send 'exit 0'
stub qs 'exit 0'

caffeine() {
  rc=0
  PATH="$stubs:$PATH" "$tool" "$@" >"$scratch/out" 2>&1 || rc=$?
}
expect_refused() {
  [[ "$rc" == 2 ]] || die "vekrona-caffeine $*: expected exit 2 (refused), got $rc: $(cat "$scratch/out")"
  grep -q '^vekrona-caffeine: ' "$scratch/out" || die "vekrona-caffeine $*: the refusal must be explained: $(cat "$scratch/out")"
}

for span in 1x 1h--2 5ms 99999999999999999999y; do
  caffeine for "$span"
  expect_refused for "$span"
done
log "ok: a span systemd-analyze rejects, or that is too short or too long, is refused with exit 2 and a reason"

: > "$scratch/systemd-run"
caffeine for 1h
[[ "$rc" == 0 ]] || die "vekrona-caffeine for 1h failed: $(cat "$scratch/out")"
grep -qF 'ExecStopPost="'"${tree//%/%%}"'/bin/vekrona-caffeine" ended' "$scratch/systemd-run" \
  || die "ExecStopPost is not one quoted word with the % of the path doubled: $(cat "$scratch/systemd-run")"
grep -qE -- '--on-calendar=[0-9-]+ [0-9:]+ UTC( |$)' "$scratch/systemd-run" || die "the deadline carries no time zone: $(cat "$scratch/systemd-run")"
log "ok: the stop command survives a path with a space and a %, and the end timer is set in UTC"

# cat ends when the writer of the pipe closes it: the watched process ends on cue, with no signal that could be lost.
mkfifo "$scratch/gate"
cat "$scratch/gate" >/dev/null &
watched=$!
timeout 30 "$tool" wait pid "$watched" &
waiter=$!
: >"$scratch/gate"
wait "$watched"
wait "$waiter" || die "waiting for a process did not end with it (exit status $?)"
log "ok: the wait for a process ends when the process does"

timeout 30 "$tool" wait pid "$watched" || die "waiting for a process that is gone must end at once, exit status $?"
log "ok: the wait for a process that is already gone ends at once"

timeout 30 "$tool" wait file "$scratch/finished.part" || die "waiting for a file that is already gone must end normally, exit status $?"
[[ ! -e "$XDG_RUNTIME_DIR/vekrona-caffeine.reason" ]] || die "a file that finished before the watch started was reported as stalled"
log "ok: a file that ended before the watch could attach ends the wait without a stall"
