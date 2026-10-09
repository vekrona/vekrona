#!/usr/bin/env bash
set -euo pipefail

# Nobody is logged in when the night run starts (the machine is at the greeter). With nothing pending it suspends
# (the suspend itself is replaced by /usr/bin/true; logind still emits PrepareForSleep). With an update pending it
# installs without asking, reboots into the offline update and reboots again, and vekrona-update-post.service reports
# the result.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/update-e2e-lib.sh"

STEP_TIMEOUT_SEC=120
BOOT_TIMEOUT_SEC=900
SUSPEND_MONITOR_SEC=120
SUSPEND_OUT=/tmp/vekrona-update-night-idle-suspend.out

boot_id() { vekrona-dev run cat /proc/sys/kernel/random/boot_id; }
# An unreachable guest answers nothing, which must not count as a new boot.
booted_again() {
  local now
  now="$(boot_id 2>/dev/null)" || return 1
  [[ "$now" != "$1" ]]
}
greeter_up() { vekrona-dev run systemctl is-active --quiet greetd 2>/dev/null; }
suspend_signalled() { vekrona-dev run grep -q '"data":\[true\]' "$SUSPEND_OUT"; }
export -f boot_id booted_again greeter_up suspend_signalled
export SUSPEND_OUT

trap 'cleanup_test_update; vekrona-dev run rm -f "$SUSPEND_OUT"' EXIT

# A greeter with nobody logged in.
previous_boot="$(boot_id)"
vekrona-dev run sudo systemctl reboot --no-block
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- booted_again "$previous_boot"
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- greeter_up
[[ -z "$(vekrona-dev run loginctl list-sessions --no-legend | awk '$6 == "user"')" ]] || die "somebody is logged in at the greeter"

vekrona-dev run sudo bash -c '
install -d "$1/systemd-suspend.service.d"
printf "[Service]\nExecStart=\nExecStart=/usr/bin/true\n" >"$1/systemd-suspend.service.d/zz-test.conf"
systemctl daemon-reload
' _ "$SYSTEM_DROPIN_DIR"
vekrona-dev spawn --root "$SUSPEND_OUT" -- timeout "$SUSPEND_MONITOR_SEC" busctl --system --json=short --limit-messages=1 \
  --match="type='signal',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'" monitor
vekrona-dev run sudo systemctl start --wait "$NIGHT_UNIT"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- suspend_signalled
log "ok: nothing pending and nobody there suspends the machine"

publish_test_update
run_check_expecting_only_the_test_update
vekrona-dev run sudo rm -rf "$SYSTEM_DROPIN_DIR/systemd-suspend.service.d"
vekrona-dev run sudo systemctl daemon-reload

previous_boot="$(boot_id)"
vekrona-dev run sudo systemctl start --no-block "$NIGHT_UNIT"
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- booted_again "$previous_boot"
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- greeter_up
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- marker_absent
log "ok: the night run installed offline, rebooted twice and vekrona-update-post consumed its marker"

[[ "$(installed_test_version)" == 2.0 ]] || die "$TEST_PKG is not at 2.0 after the offline update"
[[ "$(vekrona-dev run sudo jq -r .pending "$UPDATES_JSON")" == false ]] || die "updates.json still lists updates after the offline update"
vekrona-dev run sudo journalctl -u vekrona-update-post.service -b -o cat --no-pager | grep -q 'the offline update finished' \
  || die "vekrona-update-post did not report a finished update"
log "ok: the package is updated, updates.json is clean and the post unit reported success"
