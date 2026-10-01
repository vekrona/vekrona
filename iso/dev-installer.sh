#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF >&2
usage: $(basename "$0") [--iso PATH] [--name vekrona-auth-N] [--fresh-disk] [--print]

Boots the installer from a release ISO in a GTK window with a freshly packed
updates.img served over HTTP, so add-on edits need no ISO rebuild, and blocks
until the VM stops. A thin shim over: dev-vm.sh up --profile installer --display gtk
Set VEKRONA_DEV_USB="VID:PID ..." to pass USB devices through.
Set VEKRONA_DEV_COEXIST="NAME ..." to acknowledge foreign VMs that may keep running.
EOF
  exit "${1:-2}"
}

ISO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dev_vm="$ISO_DIR/dev-vm.sh"
session_sec=28800

name="vekrona-auth-1"
up_args=(--profile installer --display gtk --ram 6144 --ttl "$session_sec" --idle "$session_sec" --owner-pid "$$")
print_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) [[ $# -ge 2 ]] || usage; up_args+=(--iso "$2"); shift 2 ;;
    --name) [[ $# -ge 2 ]] || usage; name="$2"; shift 2 ;;
    --fresh-disk) up_args+=(--fresh-disk); shift ;;
    --print) print_only=1; shift ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
done

for foreign in ${VEKRONA_DEV_COEXIST:-}; do
  up_args+=(--coexist "$foreign")
done

if (( print_only )); then
  exec "$dev_vm" up --name "$name" "${up_args[@]}" --print
fi

trap '"$dev_vm" down --name "$name"' EXIT
"$dev_vm" up --name "$name" "${up_args[@]}"
echo "[dev-installer] installer ssh once booted: $dev_vm ssh --name $name" >&2
"$dev_vm" wait exit --name "$name" --timeout "$session_sec"
