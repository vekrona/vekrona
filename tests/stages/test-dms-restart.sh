#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# DMS exiting with status 0 mid-session must not leave the desktop without a bar.
dropin="$ROOT/config/systemd-user/dms.service.d/vekrona.conf"
grep -qx 'Restart=always' "$dropin" || die "dms.service drop-in must set Restart=always so a clean DMS exit restarts the bar"
log "ok: dms.service restarts after a clean exit"
