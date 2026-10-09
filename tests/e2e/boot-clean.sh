#!/usr/bin/env bash
# A fresh boot and login leave no failed user units, no new error records, and no QML errors from the vekrona shell.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

BOOT_TIMEOUT_SEC=240
GUEST_FAKE_AUTOSTART=/etc/xdg/autostart/nvidia-settings-user.desktop
GUEST_ERROR_STORE='$HOME/.local/state/vekrona/errors'

boot_id() { vekrona-dev run cat /proc/sys/kernel/random/boot_id; }
booted_again() { [[ "$(boot_id 2>/dev/null)" != "$1" ]]; }
error_store() { vekrona-dev run bash -c "vekrona-error list --all | awk 'NR > 1 { print \$1, \$4 }' | sort"; }
greeter_up() { vekrona-dev run systemctl is-active --quiet greetd 2>/dev/null; }
export -f boot_id booted_again greeter_up

# The NVIDIA package ships this entry but the VM has no NVIDIA driver. The generator skips entries whose Exec is missing, so the stand-in runs a binary that exists.
vekrona-dev run sudo bash -c "printf '[Desktop Entry]\nType=Application\nName=nvidia-settings Update\nExec=/usr/bin/true\n' >$GUEST_FAKE_AUTOSTART"

vekrona-dev session
previous_boot="$(boot_id)"
vekrona-dev run sudo systemctl reboot --no-block
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- booted_again "$previous_boot"
vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- greeter_up
store_before="$(error_store)"
vekrona-dev session

failed="$(vekrona-dev sh systemctl --user --failed --no-legend)"
[[ -z "$failed" ]] || die "a fresh login must leave no failed user units, but these failed: $failed"
log "ok: no failed user units"

vekrona-dev until --timeout "$BOOT_TIMEOUT_SEC" -- vekrona-dev sh systemctl --user is-active --quiet vekrona-shell.service
log "ok: the vekrona shell starts with the session"

autostart_units="$(vekrona-dev sh systemctl --user list-units --all --no-legend 'app-nvidia*')"
[[ -z "$autostart_units" ]] || die "the nvidia-settings autostart entry must stay hidden, but a unit was generated: $autostart_units"
log "ok: nvidia-settings is not autostarted"

store_after="$(error_store)"
[[ "$store_after" == "$store_before" ]] || die "a fresh boot and login must leave the error store unchanged, but it changed: $(diff <(echo "$store_before") <(echo "$store_after"))"
log "ok: the error store did not change"

shell_errors="$(vekrona-dev sh journalctl --user -b SYSLOG_IDENTIFIER=vekrona-shell --no-pager | grep -E 'ReferenceError|TypeError|is not defined|ERROR' || true)"
[[ -z "$shell_errors" ]] || die "vekrona-shell must log no QML errors, but logged: $shell_errors"
log "ok: vekrona-shell logs no QML errors"
