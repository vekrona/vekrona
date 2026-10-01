#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/authselect-vekrona.sh"

BASE=/usr/share/authselect/default/local
[[ -d "$BASE" ]] || die "authselect base profile missing: $BASE"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

render_authselect_profile "$BASE" "$work"

for f in system-auth password-auth; do
  pinned="$(grep -cF -- "$PAM_U2F_VEKRONA" "$work/$f" || true)"
  total="$(grep -cF -- 'pam_u2f.so' "$work/$f" || true)"
  [[ "$pinned" -eq 2 ]] || die "$f: expected 2 pinned pam_u2f lines, got $pinned"
  [[ "$total" -eq 2 ]] || die "$f: expected only the 2 pinned pam_u2f lines, got $total"
  grep -qE -- 'appid=pam://vekrona +\{include if "with-pam-u2f"\}' "$work/$f" \
    || die "$f: sufficient line lost its with-pam-u2f condition"
  grep -qE -- 'appid=pam://vekrona \{if not "without-pam-u2f-nouserok":nouserok\} \{include if "with-pam-u2f-2fa"\}' "$work/$f" \
    || die "$f: required line lost its nouserok and 2fa conditions"
  log "ok: $f renders two pinned pam_u2f lines with conditions intact"
done

differing="$(diff -rq "$BASE" "$work" || true)"
[[ "$(wc -l <<<"$differing")" -eq 2 ]] || die "rendering must change exactly system-auth and password-auth, diff said: $differing"
log "ok: other profile files copied unchanged"
