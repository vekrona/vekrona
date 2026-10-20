#!/usr/bin/env bash
# What root installs or runs after a check comes from a copy only root can change, never from the user's scratch directory.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh" # run_as_root: a user namespace that maps the caller to uid 0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
printf 'payload\n' >"$work/a.rpm"

run_as_root bash -c '
  source "$1"
  seen() {
    local dir="$3"
    [[ "$(stat -c %a "$dir")" == 755 ]] || { echo "mode of the root scratch dir: $(stat -c %a "$dir")" >&2; exit 1; }
    [[ "$(stat -c %u "$dir")" == 0 ]] || { echo "the root scratch dir is not root-owned" >&2; exit 1; }
    copy="$(root_owned_copy "$1" "$dir")"
    [[ "$copy" == "$dir/$(basename "$1")" ]] || { echo "copy path: $copy" >&2; exit 1; }
    [[ "$(<"$copy")" == payload && "$(stat -c "%u %a" "$copy")" == "0 644" ]] || { echo "copy: $(stat -c "%u %a" "$copy")" >&2; exit 1; }
    printf "%s" "$dir" >"$2"
  }
  with_root_scratch_dir seen "$2" "$3"
' _ "$REPO/lib/common.sh" "$work/a.rpm" "$work/dir-seen" 2>"$work/err" || die "root scratch dir misbehaves: $(cat "$work/err")"
[[ ! -e "$(<"$work/dir-seen")" ]] || die "the root scratch dir was not removed"
log "ok: a root scratch dir is root-owned and readable, holds a root-owned copy, and is removed afterwards"
