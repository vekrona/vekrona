#!/usr/bin/env bash
# Prints the number of usable FIDO security keys (hidraw devices udev tags
# ID_FIDO_TOKEN=1 that the user can read and write), once at start and again
# after every hidraw udev event. The watch is meant to run forever: any exit is
# a failure for the reader.
set -euo pipefail

# logind grants the user an ACL on a new hidraw node a few milliseconds after
# udev announces it, without a udev event. pam_u2f started before that fails
# at once, so a key counts only when its node is accessible. Until then wait
# for the ACL change (an attrib event on the node), at most 5 s.
wait_accessible() {
  local dev="$1"
  [[ -r "$dev" && -w "$dev" ]] && return 0
  # A timeout (exit 2) or a node that vanished (exit 1) just means: not usable now.
  inotifywait -qq -t 5 -e attrib "$dev" || true
  [[ -r "$dev" && -w "$dev" ]]
}

count_keys() {
  local path n=0
  for path in /sys/class/hidraw/*; do
    [[ -e "$path" ]] || continue
    if udevadm info -q property -p "$path" | grep -qx 'ID_FIDO_TOKEN=1' && wait_accessible "/dev/${path##*/}"; then
      n=$((n + 1))
    fi
  done
  printf '%d\n' "$n"
}

# The monitor prints "UDEV - the event ..." as its header once it is attached,
# and "UDEV [time] action path" for each event. Counting on both means a device
# that appears between the first count and the attach cannot be missed.
stdbuf -oL udevadm monitor --udev --subsystem-match=hidraw | while read -r line; do
  if [[ "$line" == UDEV* ]]; then
    count_keys
  fi
done
