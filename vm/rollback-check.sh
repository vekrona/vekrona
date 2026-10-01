#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
source "$ROOT/lib/common.sh"

[[ $EUID -eq 0 ]] || { echo "rollback-check must run as root" >&2; exit 1; }

[[ $# -eq 1 ]] || { echo "usage: $(basename "$0") <snapshot-number>" >&2; exit 1; }
number="$1"
[[ "$number" =~ ^[0-9]+$ ]] || { echo "snapshot number must be numeric: $number" >&2; exit 1; }

mnt="$(mktemp -d)"
cleanup() { umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT

mount_btrfs_top_level "$mnt"

[[ -d "$mnt/root" ]] || { echo "top-level subvolume 'root' not found on $(root_btrfs_device)" >&2; exit 1; }

findmnt -no SOURCE / | grep -q '\[/root\]' || { echo "/ is not mounted from the root subvolume" >&2; exit 1; }

findmnt -no SOURCE /nix | grep -q '\[/nix\]' || { echo "/nix is not mounted from the nix subvolume" >&2; exit 1; }

marker="/.vekrona-rolled-back-from-$number"
[[ -e "$marker" ]] || { echo "rollback marker not found: $marker" >&2; exit 1; }

old=""
for entry in "$mnt"/root.old-*; do
  [[ -d "$entry" ]] && old="$(basename "$entry")"
done
[[ -n "$old" ]] || { echo "no root.old-* subvolume found after rollback" >&2; exit 1; }

old_stamp="${old#root.old-}"
old_epoch="$(date -d "${old_stamp:0:8} ${old_stamp:8:2}:${old_stamp:10:2}:${old_stamp:12:2}" +%s)"
marker_epoch="$(stat -c %Y "$marker")"
(( marker_epoch - old_epoch >= 0 && marker_epoch - old_epoch <= 60 )) \
  || { echo "newest $old was not created by the rollback that wrote $marker (stamp $old_epoch, marker $marker_epoch)" >&2; exit 1; }

echo "rollback-check OK: root and $old present at the top-level mount, / on [/root], marker $marker present"
