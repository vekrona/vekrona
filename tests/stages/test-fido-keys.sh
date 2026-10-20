#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/config/vekrona-lock/fido-keys.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export SCRATCH="$scratch"

# udevadm replays a stream of monitor output; `info` finds no FIDO token among the machine's hidraw nodes.
write_fake "$stubs/udevadm" <<'F'
#!/bin/sh
case "$1" in monitor) cat "$SCRATCH/stream" ;; info) echo ID_FIDO_TOKEN=0 ;; esac
F

hidraw_event() { # hidraw_event <action> <ID_FIDO_TOKEN value or empty>
  printf 'UDEV  [100.0] %s      /devices/pci0000:00/usb5/5-1/5-1.3/5-1.3:1.4/0003:534D:2109.0001/hidraw/hidraw1 (hidraw)\n' "$1"
  printf 'ACTION=%s\nSUBSYSTEM=hidraw\nDEVNAME=/dev/hidraw1\n' "$1"
  [[ -z "$2" ]] || printf 'ID_FIDO_TOKEN=%s\n' "$2"
  printf 'SEQNUM=1\n\n'
}

scans() { PATH="$stubs:$PATH" "$tool" 2>/dev/null | wc -l; }

{
  printf 'monitor will print the received events for:\nUDEV - the event which udev sends out after rule processing\n\n'
  hidraw_event add ""
  hidraw_event remove ""
} > "$scratch/stream"
[[ "$(scans)" == 1 ]] || die "a hidraw device that is no security key must not cause a rescan, only the attach does"
log "ok: a capture card's hidraw coming and going causes no rescan"

{
  printf 'monitor will print the received events for:\nUDEV - the event which udev sends out after rule processing\n\n'
  hidraw_event add 1
  hidraw_event remove 1
} > "$scratch/stream"
[[ "$(scans)" == 3 ]] || die "a security key arriving and leaving must rescan once each, plus the attach"
log "ok: a security key arriving and leaving is counted"
