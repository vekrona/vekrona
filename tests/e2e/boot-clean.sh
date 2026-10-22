#!/usr/bin/env bash
# A fresh boot and login leave no failed user units, no new error records, and no QML errors from the vekrona shell.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

BOOT_TIMEOUT_SEC=240
GUEST_FAKE_AUTOSTART=/etc/xdg/autostart/nvidia-settings-user.desktop

error_store() { vekrona-dev run bash -c "set -o pipefail; vekrona-error list --all | awk 'NR > 1 { print \$1, \$4 }' | sort"; }

# The NVIDIA package ships this entry but the VM has no NVIDIA driver. The generator skips entries whose Exec is missing, so the stand-in runs a binary that exists.
# It does not stay in the guest for the next scenario.
trap 'vekrona-dev run sudo rm -f "$GUEST_FAKE_AUTOSTART"' EXIT
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

# The log is read whole and must hold lines of the shell at all: a journalctl that fails, or one that finds nothing because the
# shell logs under another identifier, would otherwise read as "no QML errors".
shell_log_this_boot="$(vekrona-dev sh journalctl --user -b SYSLOG_IDENTIFIER=vekrona-shell --no-pager)"
[[ -n "$shell_log_this_boot" ]] || die "the user journal holds no line of vekrona-shell for this boot, so it cannot show the shell is clean"
qml_error_lines="$(grep -E "$QML_ERROR_REGEX" <<<"$shell_log_this_boot" || [[ $? -eq 1 ]])"
[[ -z "$qml_error_lines" ]] || die "vekrona-shell must log no QML errors, but logged: $qml_error_lines"
log "ok: vekrona-shell logs no QML errors"
