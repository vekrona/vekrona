#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "rollback-check must run as root" >&2; exit 1; }

[[ $# -eq 1 ]] || { echo "usage: $(basename "$0") <snapshot-number>" >&2; exit 1; }
number="$1"
[[ "$number" =~ ^[0-9]+$ ]] || { echo "snapshot number must be numeric: $number" >&2; exit 1; }

dev="$(findmnt -no SOURCE / | sed 's/\[.*\]//')"
[[ -n "$dev" ]] || { echo "could not determine the root block device" >&2; exit 1; }

mnt="$(mktemp -d)"
cleanup() { umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT

mount -o subvolid=5 "$dev" "$mnt"

[[ -d "$mnt/root" ]] || { echo "top-level subvolume 'root' not found on $dev" >&2; exit 1; }

old=""
for entry in "$mnt"/root.old-*; do
  [[ -d "$entry" ]] && { old="$(basename "$entry")"; break; }
done
[[ -n "$old" ]] || { echo "no root.old-* subvolume found after rollback" >&2; exit 1; }

findmnt -no SOURCE / | grep -q '\[/root\]' || { echo "/ is not mounted from the root subvolume" >&2; exit 1; }

marker="/.vekrona-rolled-back-from-$number"
[[ -e "$marker" ]] || { echo "rollback marker not found: $marker" >&2; exit 1; }

echo "rollback-check OK: root and $old present at the top-level mount, / on [/root], marker $marker present"
