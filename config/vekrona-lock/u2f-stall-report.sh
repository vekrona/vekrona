#!/usr/bin/env bash
# Run by vekrona-lock when the security key attempt shows no result 40 s after its touch cue, just before
# the lock aborts the attempt. The screen is locked then and the abort kills the evidence, so the lock
# itself writes it to the journal (tag vekrona-lock): the PAM child's threads, the key's USB power state
# and the kernel's USB/HID lines. Read it after unlocking: journalctl -t vekrona-lock -b
# It never fails on a missing detail (every unreadable file is printed with its error) and ends within
# 2 s, because the lock waits for it to abort the attempt.
set -uo pipefail

if [[ -z "${STALL_REPORT_LOCKER:-}" ]]; then
  # The locker is this script's parent; under timeout it would be timeout, so name it first.
  STALL_REPORT_LOCKER="$PPID" exec timeout 2 "$0"
fi

source "$(dirname "${BASH_SOURCE[0]}")/fido-lib.sh"

# Every command's failure is part of the evidence.
show_file() {
  local out
  if out="$(cat "$1" 2>&1)"; then
    printf '%s: %s\n' "$1" "$out"
  else
    printf '%s: unreadable: %s\n' "$1" "$out"
  fi
}

# Lists pid and all its descendants.
tree() {
  local pid="$1" child
  printf '%s\n' "$pid"
  for child in $(pgrep -P "$pid"); do
    tree "$child"
  done
}

report_process() {
  local pid="$1" task
  printf 'process %s: %s\n' "$pid" "$(ps -o args= -p "$pid" 2>&1)"
  for task in /proc/"$pid"/task/*; do
    printf 'thread %s: %s\n' "${task##*/}" "$(grep -s '^State:' "$task/status" || echo 'State: unreadable')"
    show_file "$task/wchan"
    show_file "$task/syscall"
  done
  report_fds "$pid"
}

# A locker fork holds dozens of pipes and eventfds; the device nodes (the key's hidraw) are what matters.
report_fds() {
  local pid="$1" fds
  if fds="$(ls -l "/proc/$pid/fd" 2>&1)"; then
    printf 'fds of %s: %s open, device nodes:\n' "$pid" "$(grep -c -- ' -> ' <<<"$fds")"
    grep -- ' -> /dev/' <<<"$fds" || echo '(none)'
  else
    printf 'fds of %s unreadable: %s\n' "$pid" "$fds"
  fi
}

# The PAM attempt is a fork of the locker, so it carries the locker's command name; the locker's
# other children (fido-keys.sh, fprintd-list) are different programs.
report_pam_children() {
  local locker_comm child pid
  locker_comm="$(cat "/proc/$STALL_REPORT_LOCKER/comm" 2>&1)" || { printf 'cannot read the locker %s: %s\n' "$STALL_REPORT_LOCKER" "$locker_comm"; return; }
  printf 'locker %s (%s)\n' "$STALL_REPORT_LOCKER" "$locker_comm"
  for child in $(pgrep -P "$STALL_REPORT_LOCKER" -x "$locker_comm"); do
    for pid in $(tree "$child"); do
      report_process "$pid"
    done
  done
}

# The USB device is the nearest ancestor of the hidraw node that has an idVendor file.
usb_device_of() {
  local dir
  dir="$(readlink -f "$1/device")"
  while [[ "$dir" != / && ! -e "$dir/idVendor" ]]; do
    dir="$(dirname "$dir")"
  done
  printf '%s\n' "$dir"
}

report_keys() {
  local hidraw usb file found=0
  while read -r hidraw; do
    found=1
    usb="$(usb_device_of "$hidraw")"
    printf 'key %s: usb device %s\n' "${hidraw##*/}" "$usb"
    for file in power/runtime_status power/control authorized; do
      show_file "$usb/$file"
    done
  done < <(fido_hidraws)
  ((found)) || echo 'no hidraw device is tagged ID_FIDO_TOKEN=1 any more'
}

report_kernel_log() {
  local log
  if log="$(timeout 1 journalctl -k -b --no-pager 2>&1)"; then
    printf 'last kernel usb/hid lines:\n'
    grep -Ei 'usb|hid' <<<"$log" | tail -n 30
  else
    printf 'kernel log unreadable (journalctl -k exit %s): %s\n' "$?" "$log"
  fi
}

report() {
  printf 'security key stall report: no result after the touch cue\n'
  report_pam_children
  report_keys
  report_kernel_log
  printf 'end of stall report\n'
}

report 2>&1 | logger -t vekrona-lock
