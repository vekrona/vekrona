#!/usr/bin/env bash
# Prints the number of usable FIDO security keys (hidraw devices udev tags
# ID_FIDO_TOKEN=1 whose USB interface has its driver bound), once at start and
# again after every hidraw or usb udev event. A key counts only once bound:
# pam_u2f started between the hidraw add and the driver bind fails at once.
# The watch is meant to run forever: any exit is a failure for the reader.
set -euo pipefail

count_keys() {
  local path n=0
  for path in /sys/class/hidraw/*; do
    [[ -e "$path" ]] || continue
    if [[ -e "$path/device/../driver" ]] && udevadm info -q property -p "$path" | grep -qx 'ID_FIDO_TOKEN=1'; then
      n=$((n + 1))
    fi
  done
  printf '%d\n' "$n"
}

# The monitor prints "UDEV - the event ..." as its header once it is attached,
# and "UDEV [time] action path" for each event. Counting on both means a device
# that appears between the first count and the attach cannot be missed.
stdbuf -oL udevadm monitor --udev --subsystem-match=hidraw --subsystem-match=usb | while read -r line; do
  if [[ "$line" == UDEV* ]]; then
    count_keys
  fi
done
