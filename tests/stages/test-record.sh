#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-record"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch"
logs="$scratch/logs"
stubs="$scratch/stubs"
mkdir -p "$stubs"

stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }

# is-active answers with $ACTIVE_RC; the one thing the recorder is asked to do to a running recording fails.
stub systemctl 'case "$2" in
  is-active) exit "${ACTIVE_RC:-0}";;
  kill) echo "Failed to kill unit: no such unit" >&2; exit 1;;
  *) exit 99;;
esac'
stub notify-send 'echo "$*" >> "$SCRATCH/logs/notify"'
stub reporter 'echo "$*" >> "$SCRATCH/logs/reported"'
export VEKRONA_ERROR_REPORTER="$stubs/reporter"

run_record() {
  rm -rf "$logs" "$scratch/home"
  mkdir -p "$logs" "$scratch/home"
  # A file where the Videos directory belongs makes mkdir -p fail.
  [[ -z "${BLOCK_DESTINATION:-}" ]] || touch "$scratch/home/Videos"
  rc=0
  HOME="$scratch/home" PATH="$stubs:$PATH" "$tool" toggle >/dev/null 2>"$scratch/stderr" || rc=$?
}
expect_one_report() {
  [[ "$rc" == 1 ]] || die "$1: expected exit 1, got $rc: $(cat "$scratch/stderr")"
  [[ "$(wc -l < "$logs/reported" 2>/dev/null)" == 1 ]] || die "$1: expected exactly one report: $(cat "$logs/reported" 2>&1)"
  grep -q "$2" "$logs/reported" || die "$1: the report must say '$2': $(cat "$logs/reported")"
  [[ ! -e "$logs/notify" ]] || die "$1: a recorded failure needs no toast: $(cat "$logs/notify")"
}

ACTIVE_RC=0 run_record
expect_one_report "a recording that cannot be stopped" "could not stop the recording"
log "ok: a recording that cannot be stopped is reported"

ACTIVE_RC=3 BLOCK_DESTINATION=1 run_record
expect_one_report "a destination directory that cannot be created" "cannot create"
log "ok: a destination directory that cannot be created is reported"
