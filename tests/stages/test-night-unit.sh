#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# The midnight run reboots the machine into dnf's offline transaction: only on mains power, never on a laptop's battery.
unit_section="$(awk '/^\[/ { in_unit = ($0 == "[Unit]") } in_unit' "$ROOT/etc/systemd/system/vekrona-update-night.service")"
grep -qx 'ConditionACPower=true' <<<"$unit_section" || die "vekrona-update-night.service does not require AC power in its [Unit] section"
log "ok: the midnight update run requires AC power"

service_section() { awk '/^\[/ { in_service = ($0 == "[Service]") } in_service' "$ROOT/etc/systemd/system/$1.service"; }

# The midnight run only stores dnf's offline transaction, so a hung dnf can be stopped there without cutting an RPM transaction
# short; it must not keep the unit activating for ever, with the update lock held.
grep -qx 'TimeoutStartSec=2h' <<<"$(service_section vekrona-update-night)" || die "vekrona-update-night.service has no TimeoutStartSec=2h in its [Service] section"
log "ok: the update-night run is stopped after two hours"

# The update-now run installs the packages itself: a start timeout would stop dnf in the middle of its RPM transaction.
grep -qx 'TimeoutStartSec=infinity' <<<"$(service_section vekrona-update-now)" || die "vekrona-update-now.service must not time out: no TimeoutStartSec=infinity in its [Service] section"
log "ok: the update-now run, which installs packages, never times out"
