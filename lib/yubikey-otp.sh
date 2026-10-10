#!/usr/bin/env bash

# A YubiKey with its OTP interface enabled is also a USB keyboard: a touch
# while no FIDO request is pending types a 44-char OTP + Enter, which the lock
# screen submits as a wrong password.

# stdout: the /dev/input/event* node of every plugged-in Yubico (USB vendor
# 1050) device that udev classifies as a keyboard, one per line.
yubico_keyboard_nodes() {
  local db
  db="$(udevadm info --export-db)" || return 1
  awk -v RS= -F'\n' '
    {
      input = yubico = kbd = 0
      node = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "E: SUBSYSTEM=input") input = 1
        else if ($i == "E: ID_VENDOR_ID=1050") yubico = 1
        else if ($i == "E: ID_INPUT_KEYBOARD=1") kbd = 1
        else if ($i ~ /^E: DEVNAME=/) node = substr($i, 12)
      }
      if (input && yubico && kbd && node != "") print node
    }' <<<"$db"
}

yubico_has_no_keyboard() {
  local nodes
  nodes="$(yubico_keyboard_nodes)" || return 1
  [[ -z "$nodes" ]]
}
