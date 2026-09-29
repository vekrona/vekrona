#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "rollback-check must run as root" >&2; exit 1; }

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

echo "rollback-check OK: root and $old present at the top-level mount"
