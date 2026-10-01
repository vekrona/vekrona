#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$(mktemp -d)}"
source "$ROOT/iso/lib-vm.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export VEKRONA_SYSFS_ROOT="$work"
devices="$work/sys/bus/usb/devices"
drivers="$work/sys/bus/usb/drivers"

fail() { echo "FAIL: $*" >&2; exit 1; }

add_device() {
  local name="$1" vendor="$2" product="$3"
  mkdir -p "$devices/$name"
  echo "$vendor" > "$devices/$name/idVendor"
  echo "$product" > "$devices/$name/idProduct"
}

add_interface() {
  local name="$1" driver="${2:-}"
  mkdir -p "$devices/$name"
  [[ -z "$driver" ]] && return 0
  mkdir -p "$drivers/$driver"
  ln -s "../../drivers/$driver" "$devices/$name/driver"
}

add_device 1-3 1050 0407
add_interface 1-3:1.0 usbhid
add_interface 1-3:1.1 usbhid

output="$(vm_usb_require_unclaimed 1050:0407 "$devices/1-3" 2>&1)" || fail "HID-only key was refused: $output"

add_interface 1-3:1.2 usbfs
status=0
output="$(vm_usb_require_unclaimed 1050:0407 "$devices/1-3" 2>&1)" || status=$?
[[ "$status" -ne 0 ]] || fail "key with a usbfs-claimed interface was accepted"
for expected in 1050:0407 "1-3:1.0=usbhid" "1-3:1.2=usbfs" "sudo systemctl stop pcscd.socket pcscd.service"; do
  grep -qF -- "$expected" <<<"$output" || fail "refusal does not mention '$expected': $output"
done

add_device 2-1 046d c52b
add_interface 2-1:1.0
output="$(vm_usb_require_unclaimed 046d:c52b "$devices/2-1" 2>&1)" || fail "device with an unbound interface was refused: $output"

[[ "$(vm_usb_find_device 1050:0407)" == "$devices/1-3" ]] || fail "device lookup by VID:PID failed"
[[ "$(vm_usb_find_device 1050:0407 | wc -l)" == 1 ]] || fail "device lookup is not unique"
vm_usb_find_device 9999:9999 && fail "unplugged device was found"

echo "usb claim checks passed"
