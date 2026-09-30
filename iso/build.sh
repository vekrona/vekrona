#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF >&2
usage: $(basename "$0") --netinst <iso> --out <iso> [--test-ssh-pubkey <file>]

Builds a vekrona installer ISO from a verified Fedora Everything netinst ISO.
Without --test-ssh-pubkey, builds the release variant (interactive disk and
user creation). With it, builds the fully unattended test/CI variant.
EOF
  exit "${1:-2}"
}

netinst=""
out=""
ssh_pubkey=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --netinst) [[ $# -ge 2 ]] || usage; netinst="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    --test-ssh-pubkey) [[ $# -ge 2 ]] || usage; ssh_pubkey="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
done

[[ -n "$netinst" && -n "$out" ]] || usage
[[ -f "$netinst" ]] || { echo "netinst iso not found: $netinst" >&2; exit 1; }
[[ -e "$out" ]] && { echo "output already exists, refusing to overwrite: $out" >&2; exit 1; }

for c in mkksiso git xorriso; do
  command -v "$c" >/dev/null 2>&1 \
    || { echo "missing command: $c; run this on a Fedora 44 host/container with lorax installed (see iso/Containerfile)" >&2; exit 1; }
done

[[ $EUID -eq 0 ]] \
  || { echo "mkksiso needs root to rebuild the EFI boot image; run this as root (iso/Containerfile's image runs as root by default)" >&2; exit 1; }

loop_setup_hint="run this container (rootful podman/docker; rootless cannot grant device cgroup rules) with: --cap-add SYS_ADMIN --cap-add MKNOD --device /dev/loop-control --device-cgroup-rule='b 7:* rmw' --security-opt label=disable"

[[ -e /dev/loop-control ]] \
  || { echo "missing /dev/loop-control; $loop_setup_hint" >&2; exit 1; }

for i in 0 1 2 3 4 5 6 7; do
  [[ -e "/dev/loop$i" ]] && continue
  mknod -m 0660 "/dev/loop$i" b 7 "$i" \
    || { echo "could not create /dev/loop$i; $loop_setup_hint" >&2; exit 1; }
done

variant="release"
[[ -n "$ssh_pubkey" ]] && variant="test"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
git_repo() { git -c 'safe.directory=*' -C "$repo_root" "$@"; }
git_repo rev-parse HEAD >/dev/null 2>&1 \
  || { echo "not a git repository: $repo_root" >&2; exit 1; }
[[ -z "$(git_repo status --porcelain)" ]] \
  || { echo "uncommitted changes in $repo_root: the ISO embeds a clone of HEAD, so commit (or stash) first" >&2; exit 1; }
origin_url="$(git_repo remote get-url origin)" \
  || { echo "no 'origin' remote in $repo_root: the installed checkout needs it to pull updates" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

payload_dir="$workdir/vekrona-src"
git_repo clone --no-hardlinks --quiet "$repo_root" "$payload_dir"
git -C "$payload_dir" remote set-url origin "$origin_url"

ks_file="$workdir/vekrona-$variant.ks"
if [[ "$variant" == test ]]; then
  [[ -r "$ssh_pubkey" ]] || { echo "ssh pubkey file not readable: $ssh_pubkey" >&2; exit 1; }
  bash "$repo_root/iso/kickstart/render.sh" test "$ks_file" --ssh-pubkey "$ssh_pubkey"
else
  bash "$repo_root/iso/kickstart/render.sh" release "$ks_file"
fi

volid="VEKRONA-44"
mkksiso_args=(-a "$payload_dir" -V "$volid")
[[ "$variant" == test ]] && mkksiso_args+=(-c "console=ttyS0")

mkdir -p "$(dirname "$out")"
mkksiso "${mkksiso_args[@]}" "$ks_file" "$netinst" "$out"

echo "built $variant iso: $out"
