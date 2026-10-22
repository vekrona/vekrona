#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/etc/sysconfig"
FILE="$work/etc/sysconfig/kernel"
export VEKRONA_SYSFS_ROOT="$work"

# The child processes load the library alone: tests/lib.sh would set the process limits again, which the user namespace of
# run_as_root forbids.
COMMON="$REPO/lib/common.sh"
ensure() { run_as_root bash -c 'source "$1"; ensure_new_kernels_not_default' _ "$COMMON" 2>"$work/err"; }
is_no() { bash -c 'source "$1"; kernel_updatedefault_is_no' _ "$COMMON" 2>"$work/err"; }

# ensure_result DESCRIPTION CONTENT WANT: the file CONTENT ends up as WANT, and is then left alone.
ensure_result() {
  printf '%s' "$2" >"$FILE"
  ensure || die "$1: failed: $(cat "$work/err")"
  [[ "$(<"$FILE")" == "$3" ]] || die "$1: got '$(<"$FILE")', expected '$3'"
  is_no || die "$1: kernel_updatedefault_is_no is false"
  ensure || die "$1: second run failed: $(cat "$work/err")"
  [[ "$(<"$FILE")" == "$3" ]] || die "$1: the second run changed the file to '$(<"$FILE")'"
}

ensure_result "yes" $'UPDATEDEFAULT=yes\nDEFAULTKERNEL=kernel-core\n' $'UPDATEDEFAULT=no\nDEFAULTKERNEL=kernel-core'
ensure_result "quoted yes" $'UPDATEDEFAULT="yes"\nDEFAULTKERNEL=kernel-core\n' $'UPDATEDEFAULT=no\nDEFAULTKERNEL=kernel-core'
ensure_result "already no" $'UPDATEDEFAULT=no\nDEFAULTKERNEL=kernel-core\n' $'UPDATEDEFAULT=no\nDEFAULTKERNEL=kernel-core'
ensure_result "absent" $'DEFAULTKERNEL=kernel-core\n' $'DEFAULTKERNEL=kernel-core\nUPDATEDEFAULT=no'
ensure_result "absent, no final newline" 'DEFAULTKERNEL=kernel-core' $'DEFAULTKERNEL=kernel-core\nUPDATEDEFAULT=no'
ensure_result "only commented out" $'#UPDATEDEFAULT=yes\nDEFAULTKERNEL=kernel-core\n' $'#UPDATEDEFAULT=yes\nDEFAULTKERNEL=kernel-core\nUPDATEDEFAULT=no'
ensure_result "nonsense" $'UPDATEDEFAULT=maybe\n' 'UPDATEDEFAULT=no'
log "ok: UPDATEDEFAULT becomes no whatever it was (yes, quoted, absent with or without a final newline, commented out, nonsense), nothing else changes, and a second run is a no-op"

rm "$FILE"
if ensure; then die "a missing $FILE was accepted"; fi
grep -q "cannot read $FILE" "$work/err" || die "a missing file is not in the error: $(cat "$work/err")"
[[ ! -e "$FILE" ]] || die "a missing $FILE was created, which would drop DEFAULTKERNEL"
if is_no; then die "a missing $FILE read as UPDATEDEFAULT=no"; fi
grep -q "cannot read $FILE" "$work/err" || die "reading a missing file did not say so: $(cat "$work/err")"
log "ok: a missing /etc/sysconfig/kernel is an error and is not created"
