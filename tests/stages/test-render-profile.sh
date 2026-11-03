#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/authselect-vekrona.sh"

BASE=/usr/share/authselect/default/local
[[ -d "$BASE" ]] || die "authselect base profile missing: $BASE"

# A directory whose owner stat cannot read is refused too, not taken for root's: an empty owner is no uid 0.
gone="$(mktemp -u)"
refused="$( (render_authselect_profile "$BASE" "$gone") 2>&1)" && die "rendering into a directory whose owner cannot be read must be refused"
[[ ! -e "$gone" ]] || { root rm -rf "$gone"; die "a refused render still created $gone"; }
grep -qF "cannot read the owner of the authselect profile directory $gone" <<<"$refused" || die "the refusal must say why, it said: $refused"
log "ok: a directory whose owner cannot be read is refused before anything is written"

skip_as_root "a directory root made is root-owned, so the refusal below cannot be provoked"

# Root installs what is rendered, so the renderer takes only a directory the user cannot change.
user_dir="$(mktemp -d)"
trap 'rm -rf "$user_dir"' EXIT
refused="$( (render_authselect_profile "$BASE" "$user_dir") 2>&1)" && die "rendering into a directory the user owns must be refused"
[[ -z "$(ls -A "$user_dir")" ]] || die "a refused render still wrote into $user_dir"
grep -qF 'not root-owned' <<<"$refused" || die "the refusal must say why, it said: $refused"
log "ok: a directory the user owns is refused before anything is written"

work="$(root mktemp -d)"
trap 'rm -rf "$user_dir"; root rm -rf "$work"' EXIT
root chmod 0755 "$work"

render_authselect_profile "$BASE" "$work"

foreign="$(find "$work" ! -user root -print)"
[[ -z "$foreign" ]] || die "rendered files must be root-owned, these are not: $foreign"
log "ok: every rendered file is root-owned"

for f in system-auth password-auth; do
  pinned="$(grep -cF -- "$PAM_U2F_VEKRONA" "$work/$f" || true)"
  total="$(grep -cF -- 'pam_u2f.so' "$work/$f" || true)"
  [[ "$pinned" -eq 2 ]] || die "$f: expected 2 pinned pam_u2f lines, got $pinned"
  [[ "$total" -eq 2 ]] || die "$f: expected only the 2 pinned pam_u2f lines, got $total"
  grep -qE -- 'appid=pam://vekrona authfile=/etc/u2f_mappings +\{include if "with-pam-u2f"\}' "$work/$f" \
    || die "$f: sufficient line lost its with-pam-u2f condition"
  grep -qE -- 'appid=pam://vekrona authfile=/etc/u2f_mappings \{if not "without-pam-u2f-nouserok":nouserok\} \{include if "with-pam-u2f-2fa"\}' "$work/$f" \
    || die "$f: required line lost its nouserok and 2fa conditions"
  log "ok: $f renders two pinned pam_u2f lines with conditions intact"
done

differing="$(diff -rq "$BASE" "$work" || true)"
[[ "$(wc -l <<<"$differing")" -eq 2 ]] || die "rendering must change exactly system-auth and password-auth, diff said: $differing"
log "ok: other profile files copied unchanged"
