#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-with-session"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch"
stubs="$scratch/stubs"
mkdir -p "$stubs"

write_fake "$stubs/loginctl" <<'F'
#!/usr/bin/env bash
set -euo pipefail
[[ ! -e "$SCRATCH/loginctl-broken" ]] || { echo "Failed to connect to logind" >&2; exit 1; }
case "$1" in
  show-user) cat "$SCRATCH/ids";;
  show-session) cat "$SCRATCH/session-$2";;
  *) exit 99;;
esac
F
write_fake "$stubs/reporter" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$SCRATCH/reported"
F

# Lists the user's sessions: each argument is "ID TYPE SEAT CLASS STATE".
sessions() {
  local spec id type seat class state ids=()
  rm -f "$scratch"/session-* "$scratch/loginctl-broken"
  for spec in "$@"; do
    read -r id type seat class state <<<"$spec"
    ids+=("$id")
    printf 'Type=%s\nSeat=%s\nClass=%s\nState=%s\n' "$type" "$seat" "$class" "$state" >"$scratch/session-$id"
  done
  echo "${ids[*]}" >"$scratch/ids"
}

run() {
  rc=0
  rm -f "$scratch/reported"
  out="$(PATH="$stubs:$PATH" VEKRONA_ERROR_REPORTER="$stubs/reporter" "$tool" sh -c 'echo "$XDG_SESSION_ID"' 2>"$scratch/stderr")" || rc=$?
}
expect_session() {
  run
  [[ "$rc" == 0 && "$out" == "$1" ]] || die "$2: expected the command to see session $1, got exit $rc and '$out': $(cat "$scratch/stderr")"
  log "ok: $2"
}
expect_failure() {
  local reported="${3:-$1}"
  run
  [[ "$rc" != 0 && -z "$out" ]] || die "$2: expected a failure that runs nothing, got exit $rc and '$out'"
  grep -q -- "$1" "$scratch/stderr" || die "$2: the failure must say '$1': $(cat "$scratch/stderr")"
  grep -q -- "$reported" "$scratch/reported" || die "$2: the failure must become an error record, so that nobody finds out only when the machine never suspends: $(cat "$scratch/reported" 2>&1)"
  log "ok: $2"
}

sessions "1 wayland seat0 user active"
expect_session 1 "the graphical session is passed on"

sessions "2 tty - user active" "5 wayland seat0 user active" "9 tty - user active"
expect_session 5 "a text or ssh login before the sway session is skipped"

sessions "3 x11 seat0 user active"
expect_session 3 "an X11 session counts as graphical"

sessions "2 tty - user active"
expect_failure "no graphical session on seat0" "a user with only text logins fails"

sessions "4 wayland seat0 user closing"
expect_failure "no graphical session on seat0" "a closing graphical session does not count"

sessions "6 wayland seat1 user active"
expect_failure "no graphical session on seat0" "a graphical session on another seat does not count"

sessions "7 wayland seat0 greeter active"
expect_failure "no graphical session on seat0" "the greeter does not count"

sessions "1 wayland seat0 user active" "8 wayland seat0 user online"
expect_failure "several graphical sessions" "two graphical sessions are ambiguous"

touch "$scratch/loginctl-broken"
expect_failure "Failed to connect to logind" "a logind that does not answer fails instead of picking nothing" "cannot list the sessions"

rc=0
PATH="$stubs:$PATH" "$tool" 2>"$scratch/stderr" || rc=$?
[[ "$rc" != 0 ]] && grep -q usage "$scratch/stderr" || die "a call without a command must fail with the usage"
log "ok: no command is a usage error"
