#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-idlehint"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch"
stubs="$scratch/stubs"
mkdir -p "$stubs"

write_fake "$stubs/loginctl" <<'F'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  show-user) echo "$SESSIONS";;
  show-session) printf 'Type=wayland\nSeat=seat0\nClass=user\nState=active\n';;
  *) exit 99;;
esac
F
write_fake "$stubs/busctl" <<'F'
#!/usr/bin/env bash
echo "$*" >"$SCRATCH/busctl"
F

run() {
  rc=0
  rm -f "$scratch/busctl"
  PATH="$stubs:$PATH" "$tool" "$@" 2>"$scratch/stderr" || rc=$?
}
expect_call() {
  local want="$1" description="$2"
  shift 2
  run "$@"
  [[ "$rc" == 0 && "$(<"$scratch/busctl")" == "--system call org.freedesktop.login1 $want" ]] \
    || die "$description: exit $rc, busctl got '$(cat "$scratch/busctl" 2>&1)': $(cat "$scratch/stderr")"
  log "ok: $description"
}

SESSIONS=6 expect_call "/org/freedesktop/login1/session/_36 org.freedesktop.login1.Session SetIdleHint b true" "yes sets the hint on the graphical session" yes
SESSIONS=6 expect_call "/org/freedesktop/login1/session/_36 org.freedesktop.login1.Session SetIdleHint b false" "no clears it" no
SESSIONS=c12 expect_call "/org/freedesktop/login1/session/c12 org.freedesktop.login1.Session SetIdleHint b true" "letters and later digits of a session id stay as they are" yes
SESSIONS=12 expect_call "/org/freedesktop/login1/session/_312 org.freedesktop.login1.Session SetIdleHint b true" "only a leading digit is escaped" yes

for args in "" "maybe" "yes no"; do
  SESSIONS=6 run $args
  [[ "$rc" == 2 && ! -e "$scratch/busctl" ]] || die "'$args' must be a usage error that calls nothing, got exit $rc"
done
log "ok: anything but yes or no is a usage error"
