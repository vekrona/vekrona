#!/usr/bin/env bash
# The shell's Bluetooth toggle powers an adapter on that rfkill soft-blocked, against a virtual BlueZ controller.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
BTVIRT=/usr/libexec/bluetooth/btvirt
BTVIRT_LOG=/tmp/vekrona-btvirt.log

controller_listed() { [[ -n "$(vekrona-dev run bluetoothctl list)" ]]; }
rfkill_state() { vekrona-dev run rfkill --noheadings --output SOFT list bluetooth; }
soft_blocked() { [[ "$(rfkill_state)" == blocked ]]; }
soft_unblocked() { [[ "$(rfkill_state)" == unblocked ]]; }
adapter_powered() { vekrona-dev run bluetoothctl show | grep -q 'Powered: yes'; }
adapter_unpowered() { vekrona-dev run bluetoothctl show | grep -q 'Powered: no'; }
toggle_row_listed() { text_shown 'Turn Bluetooth on'; }
export -f controller_listed rfkill_state soft_blocked soft_unblocked adapter_powered adapter_unpowered toggle_row_listed

# systemd-rfkill saves the soft-block state of Bluetooth and puts it on the next controller that appears, so a controller
# removed while blocked would start the next run unpowered: the block ends before the controller goes.
remove_virtual_controller() {
  vekrona-dev run sudo rfkill unblock bluetooth
  kill_guest_root -x btvirt
}
cleanup() {
  run_cleanups close_launcher remove_virtual_controller
}

# hci_vhci lives in kernel-modules and btvirt in bluez-libs-devel; the guest ships neither.
vekrona-dev run sudo bash -c 'rpm -q --quiet "kernel-modules-$(uname -r)" bluez-libs-devel || dnf install -y --repo=fedora,updates "kernel-modules-$(uname -r)" bluez-libs-devel'
vekrona-dev run sudo modprobe hci_vhci
trap cleanup EXIT
remove_virtual_controller

vekrona-dev spawn --root "$BTVIRT_LOG" -- "$BTVIRT" -l1
# bluetooth.service is conditioned on /sys/class/bluetooth existing when it starts, so it starts after the controller.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev run test -e /sys/class/bluetooth/hci0
vekrona-dev run sudo rfkill unblock bluetooth
vekrona-dev run sudo systemctl restart bluetooth.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- controller_listed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- adapter_powered
log "ok: a virtual controller is up and powered"

vekrona-dev session
# The shell meets BlueZ when it starts: one that started before the controller never sees its adapter.
restart_shell
vekrona-dev move 600 500
clear_notifications

vekrona-dev run sudo rfkill block bluetooth
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- soft_blocked
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- adapter_unpowered
log "ok: the controller is soft-blocked and BlueZ reports it unpowered"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type bt
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- toggle_row_listed
log "ok: the launcher offers to turn Bluetooth on"

# The row is not the first result for "bt" (apps rank above settings): it is picked by clicking its subtitle, one word that
# nothing else on the screen has, and Enter would start btop.
vekrona-dev click-text '^rfkill$'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- soft_unblocked \
  || die "the Bluetooth toggle left the adapter rfkill-blocked; the shell logged: $(vekrona-dev sh journalctl --user -b SYSLOG_IDENTIFIER=vekrona-shell --no-pager | grep -i 'rfkill' || echo nothing about rfkill)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- adapter_powered \
  || die "the Bluetooth toggle unblocked rfkill but BlueZ still reports the adapter unpowered"
log "ok: the toggle unblocks rfkill and powers the adapter"
