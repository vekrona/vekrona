#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/geoclue.sh"
SHIPPED="$ROOT/etc/geoclue/conf.d/90-vekrona.conf"

rendered="$(render_geoclue_conf 1234 <"$SHIPPED")"
[[ "$(grep -c '^users=' <<<"$rendered")" -eq 1 && "$(grep '^users=' <<<"$rendered")" == users=1234 ]] \
  || die "the app is not limited to the one uid: $rendered"
[[ "$(grep -v '^users=' <<<"$rendered")" == "$(grep -v '^users=' "$SHIPPED")" ]] || die "render_geoclue_conf changed more than the users line"
log "ok: the geoclue app config lists exactly the given uid and nothing else changes"

if (render_geoclue_conf "" <"$SHIPPED") >/dev/null 2>&1; then die "an empty uid (all users) was accepted"; fi
if (render_geoclue_conf "root" <"$SHIPPED") >/dev/null 2>&1; then die "a user name instead of a uid was accepted"; fi
if (render_geoclue_conf 1000 <<<$'[app]\nallowed=true') >/dev/null 2>&1; then die "a config without a users= line was accepted"; fi
log "ok: an empty or non-numeric uid and a config with no users= line are refused"
