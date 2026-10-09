#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/yubikey-otp.sh"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/bin"
cat >"$dir/bin/udevadm" <<'FAKE'
#!/usr/bin/env bash
[[ "$*" == "info --export-db" ]] || { echo "fake udevadm: unexpected args: $*" >&2; exit 2; }
cat "$FAKE_UDEV_DB"
FAKE
chmod +x "$dir/bin/udevadm"
export PATH="$dir/bin:$PATH" FAKE_UDEV_DB="$dir/db"

# one udev input record: P: line, then E: properties
rec() {
  local vendor="$1" kbd="$2" devname="$3"
  printf 'P: /devices/fake%s\nE: SUBSYSTEM=input\nE: ID_VENDOR_ID=%s\nE: DEVNAME=%s\n' "$devname" "$vendor" "$devname"
  [[ "$kbd" == 0 ]] || printf 'E: ID_INPUT_KEYBOARD=1\n'
  printf '\n'
}

expect_clean() {
  yubico_has_no_keyboard || die "$1: must pass, found: $(yubico_keyboard_nodes)"
  log "ok: $1"
}
expect_found() {
  local what="$1" want="$2" got
  ! yubico_has_no_keyboard || die "$what: must fail"
  got="$(yubico_keyboard_nodes)"
  [[ "$got" == "$want" ]] || die "$what: wanted $want, got $got"
  log "ok: $what"
}

: >"$dir/db"
expect_clean "no devices at all passes"

{ rec 046d 1 /dev/input/event3; rec 046d 0 /dev/input/event4; } >"$dir/db"
expect_clean "a non-Yubico keyboard passes"

{ rec 1050 0 /dev/input/event5; rec 046d 1 /dev/input/event3; } >"$dir/db"
expect_clean "a Yubico device without a keyboard (FIDO only) passes"

{ rec 1050 1 /dev/input/event1; rec 046d 1 /dev/input/event3; } >"$dir/db"
expect_found "a Yubico keyboard fails and is named" /dev/input/event1

{ rec 1050 1 /dev/input/event1; rec 1050 1 /dev/input/event7; } >"$dir/db"
expect_found "every Yubico keyboard is named" $'/dev/input/event1\n/dev/input/event7'

printf 'garbage' >"$dir/db"
expect_clean "an unparsable db lists no keyboard"

cat >"$dir/bin/udevadm" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
! yubico_has_no_keyboard || die "a failing udevadm must fail the check, not pass it"
log "ok: a failing udevadm fails the check"
