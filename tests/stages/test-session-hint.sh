#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-session-hint"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch"
stubs="$scratch/stubs"
mkdir -p "$stubs" "$scratch/run"

SWAY_PID=4242
SWAY_SESSION_PATH=/org/freedesktop/login1/session/_36

# sway answers on its socket unless SWAY_GONE is set.
write_fake "$stubs/swaymsg" <<'F'
#!/usr/bin/env bash
[[ -z "${SWAY_GONE:-}" ]]
F
# logind knows sway's PID unless NO_SESSION is set, and refuses the hints when REFUSE names the method.
write_fake "$stubs/busctl" <<'F'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "--system call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager GetSessionByPID u 4242")
    [[ -z "${NO_SESSION:-}" ]] || { echo "Call failed: PID 4242 does not belong to any known session" >&2; exit 1; }
    echo 'o "/org/freedesktop/login1/session/_36"';;
  "--system call org.freedesktop.login1 /org/freedesktop/login1/session/"*)
    [[ "$*" != *" ${REFUSE:-none}"* ]] || { echo "Call failed: Access denied" >&2; exit 1; }
    call="$*"
    echo "${call#--system call org.freedesktop.login1 }" >>"$SCRATCH/calls";;
  *) echo "unexpected busctl call: $*" >&2; exit 99;;
esac
F
write_fake "$stubs/reporter" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$SCRATCH/reported"
F

run() {
  rc=0
  rm -f "$scratch/calls" "$scratch/reported"
  PATH="$stubs:$PATH" VEKRONA_ERROR_REPORTER="$stubs/reporter" XDG_RUNTIME_DIR="$scratch/run" \
    SWAYSOCK="$scratch/run/sway-ipc.1000.$SWAY_PID.sock" "$tool" "$@" 2>"$scratch/stderr" || rc=$?
}
expect_calls() {
  local description="$1" want="$2"
  shift 2
  run "$@"
  [[ "$rc" == 0 && "$(cat "$scratch/calls" 2>/dev/null)" == "$want" ]] \
    || die "$description: exit $rc, logind got '$(cat "$scratch/calls" 2>&1)': $(cat "$scratch/stderr")"
  log "ok: $description"
}
# A failure sets nothing on any session, says why, and becomes an error record.
expect_failure() {
  local description="$1" reason="$2" want="$3"
  shift 3
  run "$@"
  [[ "$rc" != 0 && "$rc" != 2 && "$(cat "$scratch/calls" 2>/dev/null)" == "$want" ]] \
    || die "$description: expected a failure, got exit $rc and logind calls '$(cat "$scratch/calls" 2>&1)'"
  grep -q -- "$reason" "$scratch/stderr" || die "$description: the failure must say '$reason': $(cat "$scratch/stderr")"
  grep -q -- "$reason" "$scratch/reported" || die "$description: the failure must become an error record: $(cat "$scratch/reported" 2>&1)"
  log "ok: $description"
}

session="$SWAY_SESSION_PATH org.freedesktop.login1.Session"
expect_calls "the lock screen marks sway's own session locked" "$session SetLockedHint b true" locked yes
expect_calls "unlocking clears sway's locked hint, then signals the unlock" "$session SetLockedHint b false
$session Unlock" locked no
expect_calls "swayidle's idle hint goes to sway's session" "$session SetIdleHint b true" idle yes
expect_calls "input clears it there" "$session SetIdleHint b false" idle no

NO_SESSION=1 expect_failure "a sway that logind places in no session marks no session unlocked" \
  "logind names no login session for sway (PID $SWAY_PID" "" locked no
SWAY_GONE=1 expect_failure "without a running sway no session is marked unlocked" \
  "no sway session runs" "" locked no
REFUSE=SetLockedHint expect_failure "a refused hint is reported, and no unlock is signalled for a session still marked locked" \
  "logind refused SetLockedHint false on sway's session $SWAY_SESSION_PATH" "" locked no

for args in "" "locked" "locked maybe" "sleepy yes" "idle yes no"; do
  # shellcheck disable=SC2086 # each case is a list of words
  run $args
  [[ "$rc" == 2 && ! -e "$scratch/calls" ]] || die "'$args' must be a usage error that calls nothing, got exit $rc"
done
log "ok: anything but idle or locked with yes or no is a usage error"
