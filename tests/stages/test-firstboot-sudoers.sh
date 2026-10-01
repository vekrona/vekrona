#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

sed -n '/^cat > "[$]SUDOERS_DROPIN" <<EOF$/,/^EOF$/p' "$ROOT/iso/firstboot/vekrona-firstboot" \
  | sed '1d;$d;s/\$user/firstboot-admin/g' >"$work/dropin"

[[ -s "$work/dropin" ]] || die "could not extract the sudoers drop-in from iso/firstboot/vekrona-firstboot"
grep -qxF 'firstboot-admin ALL=(ALL) NOPASSWD: ALL' "$work/dropin" || die "drop-in lacks NOPASSWD for the admin"
grep -qxF 'Defaults:firstboot-admin !authenticate' "$work/dropin" \
  || die "drop-in lacks '!authenticate': sudo would run the PAM auth stack (pam_u2f asks for a touch) once stage 45 enables it"
visudo -cf "$work/dropin" >/dev/null || die "extracted sudoers drop-in does not parse"
log "ok: first-boot sudo never authenticates, so pam_u2f cannot ask for a touch during first boot"
