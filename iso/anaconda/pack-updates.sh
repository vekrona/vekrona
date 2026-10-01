#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <out-updates.img>" >&2
  exit "${1:-2}"
}

[[ $# -eq 1 ]] || usage
[[ "$1" != -h && "$1" != --help ]] || usage 0
out_img="$(realpath -m "$1")"

die() { echo "pack-updates: $*" >&2; exit 1; }

anaconda_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$anaconda_dir/../.." && pwd)"
updates_root="$anaconda_dir/updates"
bundle_list="$anaconda_dir/bundle.list"
cache_dir="$anaconda_dir/.cache"
fedora_release=44

for c in cpio rpm2cpio gzip dnf sha256sum git rsync; do
  command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
done
[[ -d "$updates_root" ]] || die "missing anaconda updates tree: $updates_root"
[[ -r "$bundle_list" ]] || die "missing bundle list: $bundle_list"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
rsync -a --exclude=__pycache__ --exclude='*.pyc' "$updates_root/" "$staging/"

mkdir -p "$cache_dir"
while read -r nevra sha256; do
  [[ -n "$nevra" ]] || continue
  [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "bad sha256 for $nevra in $bundle_list"
  rpm_file="$cache_dir/$nevra.rpm"
  if [[ ! -f "$rpm_file" ]]; then
    download_dir="$(mktemp -d "$cache_dir/.download.XXXXXX")"
    dnf download --releasever="$fedora_release" --destdir "$download_dir" "$nevra" >&2 \
      || { rm -rf "$download_dir"; die "dnf download failed for $nevra"; }
    [[ -f "$download_dir/$nevra.rpm" ]] \
      || { rm -rf "$download_dir"; die "dnf download did not produce $nevra.rpm"; }
    mv "$download_dir/$nevra.rpm" "$rpm_file"
    rmdir "$download_dir"
  fi
  actual="$(sha256sum "$rpm_file" | cut -d' ' -f1)"
  [[ "$actual" == "$sha256" ]] \
    || die "sha256 mismatch for $nevra: expected $sha256, got $actual (delete $rpm_file to re-download)"
  (cd "$staging" && rpm2cpio "$rpm_file" | cpio --quiet -idm) \
    || die "could not extract $rpm_file"
done < "$bundle_list"

rm -rf "$staging/usr/share/doc" "$staging/usr/share/man"
find "$staging" -name __pycache__ -prune -exec rm -rf {} +
find "$staging" -name '*.pyc' -delete

stamp_dir="$staging/usr/share/anaconda/addons/vekrona_signin"
mkdir -p "$stamp_dir"
commit="$(git -c "safe.directory=*" -C "$repo_root" rev-parse --short HEAD)" \
  || die "git rev-parse failed in $repo_root"
dirty_files="$(git -c "safe.directory=*" -C "$repo_root" status --porcelain)" \
  || die "git status failed in $repo_root"
stamp="$commit"
[[ -z "$dirty_files" ]] || stamp+="-dirty"
stamp+="${VEKRONA_UPDATES_STAMP_EXTRA:+ $VEKRONA_UPDATES_STAMP_EXTRA}"
echo "$stamp" > "$stamp_dir/.build-stamp"

commit_time="$(git -c "safe.directory=*" -C "$repo_root" log -1 --format=%ct)" \
  || die "git log failed in $repo_root"
find "$staging" -exec touch -h -d "@$commit_time" {} +

mkdir -p "$(dirname "$out_img")"
(
  cd "$staging"
  find . ! -path . | LC_ALL=C sort \
    | cpio --quiet -o -H newc --reproducible --owner=0:0 \
    | gzip -n -9
) > "$out_img"
