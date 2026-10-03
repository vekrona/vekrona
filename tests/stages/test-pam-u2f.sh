#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
source "$ROOT/lib/pam-u2f.sh"

stripped() {
  printf '%s' "$1" | u2f_keys_without_pin_flag
  printf x
}

expect_stripped() {
  local what="$1" input="$2" want="$3" got
  got="$(stripped "$input")"
  got="${got%x}"
  [[ "$got" == "$want" ]] || die "$what: wanted $(printf %q "$want"), got $(printf %q "$got")"
  log "ok: $what"
}

expect_stripped "+presence+pin loses +pin" 'u:aB1=,cD2=,es256,+presence+pin
' 'u:aB1=,cD2=,es256,+presence
'
expect_stripped "+presence+verification+pin loses +pin only" 'u:aB1=,cD2=,es256,+presence+verification+pin
' 'u:aB1=,cD2=,es256,+presence+verification
'
expect_stripped "a lone +pin leaves empty attributes" 'u:aB1=,cD2=,es256,+pin
' 'u:aB1=,cD2=,es256,
'
expect_stripped "+pin in the middle loses +pin" 'u:aB1=,cD2=,es256,+presence+pin+verification
' 'u:aB1=,cD2=,es256,+presence+verification
'
expect_stripped "two credentials on one line are both cleaned" 'u:aB1=,cD2=,es256,+presence+pin:eF3=,gH4=,es256,+pin+presence
' 'u:aB1=,cD2=,es256,+presence:eF3=,gH4=,es256,+presence
'
expect_stripped "+pin inside a base64 key handle is untouched" 'u:ab+pinCD==,ef+pinGH==,es256,+presence+pin
' 'u:ab+pinCD==,ef+pinGH==,es256,+presence
'
expect_stripped "an attribute that merely starts with +pin is untouched" 'u:aB1=,cD2=,es256,+pinned+presence
' 'u:aB1=,cD2=,es256,+pinned+presence
'
expect_stripped "an already clean line is unchanged" 'u:aB1=,cD2=,es256,+presence
' 'u:aB1=,cD2=,es256,+presence
'
expect_stripped "a credential with empty attributes is unchanged" 'u:aB1=,cD2=,es256,
' 'u:aB1=,cD2=,es256,
'
expect_stripped "an empty file stays empty" '' ''
expect_stripped "a user without credentials is unchanged" 'user
' 'user
'
expect_stripped "garbage is unchanged" 'lizard' 'lizard'
expect_stripped "a missing final newline stays missing" 'u:aB1=,cD2=,es256,+presence+pin' 'u:aB1=,cD2=,es256,+presence'
expect_stripped "other users' lines and blank lines are kept byte for byte" 'a:x,y,es256,+presence+pin

b:x,y,es256,+presence
' 'a:x,y,es256,+presence

b:x,y,es256,+presence
'

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
export XDG_CONFIG_HOME="$dir/cfg"

ensure_u2f_keys_without_pin_flag
[[ ! -e "$(u2f_keys_path)" ]] || die "a missing u2f_keys must not be created"
log "ok: a missing u2f_keys is a no-op"

mkdir -p "$XDG_CONFIG_HOME/Yubico"
printf 'u:aB1=,cD2=,es256,+presence+pin\n' >"$(u2f_keys_path)"
chmod 0640 "$(u2f_keys_path)"
u2f_keys_have_pin_flag "$(u2f_keys_path)" || die "a +pin credential must be detected"
ensure_u2f_keys_without_pin_flag
[[ "$(<"$(u2f_keys_path)")" == 'u:aB1=,cD2=,es256,+presence' ]] || die "the file was not migrated"
[[ "$(stat -c %a "$(u2f_keys_path)")" == 640 ]] || die "the file mode was not preserved"
! u2f_keys_have_pin_flag "$(u2f_keys_path)" || die "the migrated file still reads as carrying +pin"
[[ "$(ls "$XDG_CONFIG_HOME/Yubico")" == u2f_keys ]] || die "a temp file was left behind"
log "ok: the migration strips +pin in place, keeps the mode and leaves no temp file"

before="$(stat -c %i "$(u2f_keys_path)")"
ensure_u2f_keys_without_pin_flag
[[ "$(stat -c %i "$(u2f_keys_path)")" == "$before" ]] || die "an already clean file was rewritten"
log "ok: an already clean file is not rewritten"
