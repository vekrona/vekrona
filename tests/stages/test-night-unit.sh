#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# The midnight run reboots the machine into dnf's offline transaction: only on mains power, never on a laptop's battery.
unit_section="$(awk '/^\[/ { in_unit = ($0 == "[Unit]") } in_unit' "$ROOT/etc/systemd/system/vekrona-update-night.service")"
grep -qx 'ConditionACPower=true' <<<"$unit_section" || die "vekrona-update-night.service does not require AC power in its [Unit] section"
log "ok: the midnight update run requires AC power"
