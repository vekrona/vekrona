#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/stubs"
cat >"$scratch/stubs/systemctl" <<STUB
#!/bin/sh
echo "\$@" >>"$scratch/systemctl.log"
case "\$*" in
  *"show -p LoadState"*) cat "$scratch/loadstate" ;;
  *"disable --now old.service") exit "\$(cat "$scratch/disable.status" 2>/dev/null || echo 0)" ;;
esac
STUB
chmod +x "$scratch/stubs/systemctl"
export PATH="$scratch/stubs:$PATH"
disables() { grep -c -- 'disable --now old.service' "$scratch/systemctl.log" || true; }

echo not-found >"$scratch/loadstate"
: >"$scratch/systemctl.log"
ensure_user_unit_stopped old.service
[[ "$(disables)" == 0 ]] || die "an old.service that is not loaded must be left alone"
log "ok: no such unit, nothing to stop"

echo loaded >"$scratch/loadstate"
ensure_user_unit_stopped old.service
[[ "$(disables)" == 1 ]] || die "a loaded unit must be disabled and stopped"
log "ok: a live unit is disabled and stopped"

echo 1 >"$scratch/disable.status"
if (ensure_user_unit_stopped old.service) 2>/dev/null; then die "an old.service that cannot be stopped must fail"; fi
log "ok: a unit that will not stop fails the stage"
