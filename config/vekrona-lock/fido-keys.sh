#!/usr/bin/env bash
# Prints the number of usable FIDO security keys (hidraw devices udev tags
# ID_FIDO_TOKEN=1 that the user can read and write), once at start and again
# after every hidraw udev event. The watch is meant to run forever: any exit is
# a failure for the reader.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/fido-lib.sh"

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
  while read -r path; do
    if wait_accessible "/dev/${path##*/}"; then
      n=$((n + 1))
    fi
  done < <(fido_hidraws)
  printf '%d\n' "$n"
}

# The monitor prints "UDEV - the event ..." as its header once it is attached,
# and "UDEV [time] action path" for each event, followed by the event's properties
# (--property) up to an empty line. Counting on the header means a device that
# appears between the first count and the attach cannot be missed. An event
# counts only when its properties tag a FIDO token: any other hidraw device (a
# capture card's, a KVM's) coming and going cannot change the number of keys,
# and a removed key still carries its tag, which sysfs no longer could say.
fido_event=0
stdbuf -oL udevadm monitor --udev --property --subsystem-match=hidraw | while IFS= read -r line; do
  case "$line" in
    "UDEV - "*) count_keys ;;
    UDEV*) fido_event=0 ;;
    ID_FIDO_TOKEN=1) fido_event=1 ;;
    "")
      if ((fido_event)); then
        fido_event=0
        count_keys
      fi
      ;;
  esac
done
