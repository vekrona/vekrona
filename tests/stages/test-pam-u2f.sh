#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/authselect-vekrona.sh"
source "$ROOT/lib/pam-u2f.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/sysroot/etc" "$scratch/config/Yubico"
# `root` is sudo: the stub runs the command as the invoking user, which owns everything below $scratch.
write_fake "$scratch/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
export PATH="$scratch/bin:$PATH" XDG_CONFIG_HOME="$scratch/config"
unset VEKRONA_SYSFS_ROOT
U2F_MAPPINGS="$scratch/sysroot/etc/u2f_mappings"
legacy="$(u2f_keys_path)"
me="$VEKRONA_USER"

# Every PAM stack that asks for the key reads the same root-owned registration, and asks for the PIN.
for args in "$PAM_U2F_VEKRONA" "$(sed -n 's/^auth .*required  *//p' "$ROOT/etc/pam.d/vekrona-lock-u2f")"; do
  [[ " $args " == *" authfile=/etc/u2f_mappings "* ]] || die "a pam_u2f line does not read /etc/u2f_mappings: $args"
  [[ " $args " == *" pinverification=1 "* ]] || die "a pam_u2f line does not require the PIN: $args"
  [[ " $args " != *" authfile=~"* && " $args " != *".config/Yubico"* ]] || die "a pam_u2f line reads a file the user can write: $args"
done
[[ "$(sed -n 's/^auth .*required  *//p' "$ROOT/etc/pam.d/vekrona-lock-u2f")" == "$PAM_U2F_VEKRONA" ]] \
  || die "the lock screen's pam_u2f arguments differ from system-auth's (sudo, polkit and the greeter)"
log "ok: sudo, polkit, the greeter and the lock screen read /etc/u2f_mappings and all ask for the PIN and a touch"

ensure_u2f_mappings
[[ ! -e "$U2F_MAPPINGS" ]] || die "$U2F_MAPPINGS was created without any registration"
log "ok: with no registration at all nothing is created"

printf '%s:aB1=,cD2=,es256,+presence\nroot:eVi1=,l2=,es256,+presence\nmallory:x=,y=,es256,+presence\n' "$me" >"$legacy"
ensure_u2f_mappings
[[ "$(<"$U2F_MAPPINGS")" == "$me:aB1=,cD2=,es256,+presence" ]] \
  || die "only the user's own line may move into root's registration (a root: line would sign a user process in as root): $(<"$U2F_MAPPINGS")"
[[ "$(stat -c %a "$U2F_MAPPINGS")" == 644 ]] || die "$U2F_MAPPINGS must be readable by the lock screen, which runs pam_u2f as the user: $(stat -c %a "$U2F_MAPPINGS")"
log "ok: the user's registration moves into $U2F_MAPPINGS, other users' lines stay behind, mode 0644"

printf '%s:newKey=,newKey2=,es256,+presence\n' "$me" >"$legacy"
ensure_u2f_mappings
[[ "$(<"$U2F_MAPPINGS")" == "$me:aB1=,cD2=,es256,+presence" ]] || die "a file the user can write replaced root's registration: $(<"$U2F_MAPPINGS")"
log "ok: an existing $U2F_MAPPINGS is never replaced from the user's file"

rm "$U2F_MAPPINGS"
printf 'mallory:x=,y=,es256,+presence\n' >"$legacy"
ensure_u2f_mappings 2>"$scratch/err"
[[ ! -e "$U2F_MAPPINGS" ]] || die "a registration of someone else was adopted"
grep -q "holds no registration for $me" "$scratch/err" || die "the missing registration is not said: $(cat "$scratch/err")"
[[ -z "$(ls "$scratch/sysroot/etc")" ]] || die "a temp file was left behind: $(ls "$scratch/sysroot/etc")"
log "ok: a legacy file with no line of the user is reported and moves nothing"
