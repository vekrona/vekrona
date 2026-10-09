#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

unit="$ROOT/iso/firstboot/vekrona-firstboot.service"

# A retried install ends in a reboot and restarts the user's session, so nobody may log in while it runs.
before="$(sed -n 's/^Before=//p' "$unit")"
for login in getty@tty1.service display-manager.service; do
  [[ " $before " == *" $login "* ]] || die "first-boot install is not ordered before $login (Before=$before)"
done
log "ok: first-boot install finishes before any login prompt or greeter starts"
