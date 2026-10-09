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
toggle_row_listed() { vekrona-dev see text 'Turn Bluetooth on'; }
export -f controller_listed rfkill_state soft_blocked soft_unblocked adapter_powered adapter_unpowered toggle_row_listed

remove_virtual_controller() { vekrona-dev run sudo pkill -x btvirt || true; }

export PANEL_HEX="$(vekrona_token_get color surface-1 dark)"

# hci_vhci lives in kernel-modules and btvirt in bluez-libs-devel; the guest ships neither.
vekrona-dev run sudo bash -c 'rpm -q --quiet "kernel-modules-$(uname -r)" bluez-libs-devel || dnf install -y --repo=fedora,updates "kernel-modules-$(uname -r)" bluez-libs-devel'
vekrona-dev run sudo modprobe hci_vhci
trap remove_virtual_controller EXIT
remove_virtual_controller

vekrona-dev spawn --root "$BTVIRT_LOG" -- "$BTVIRT" -l1
# bluetooth.service is conditioned on /sys/class/bluetooth existing when it starts, so it starts after the controller.
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- vekrona-dev run test -e /sys/class/bluetooth/hci0
vekrona-dev run sudo systemctl restart bluetooth.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- controller_listed
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- adapter_powered
log "ok: a virtual controller is up and powered"

vekrona-dev session
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

vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- soft_unblocked \
  || die "the Bluetooth toggle left the adapter rfkill-blocked; the shell logged: $(vekrona-dev sh journalctl --user -b SYSLOG_IDENTIFIER=vekrona-shell --no-pager | grep -i 'rfkill' || echo nothing about rfkill)"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- adapter_powered \
  || die "the Bluetooth toggle unblocked rfkill but BlueZ still reports the adapter unpowered"
log "ok: the toggle unblocks rfkill and powers the adapter"
