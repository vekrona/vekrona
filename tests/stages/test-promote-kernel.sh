#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"

# The child processes load the library alone: tests/lib.sh would set the process limits again, which the user namespace of
# run_as_root forbids.
COMMON="$REPO/lib/common.sh"
OLD_KVER=7.2.9-200.fc44.x86_64 NEW_KVER=7.2.10-200.fc44.x86_64

default_kernel() { cat "$work/default-kernel"; }
promote() { run_as_root bash -c 'source "$1"; promote_kernel_if_nvidia_ready "$2"' _ "$COMMON" "$1" 2>"$work/err"; }
reset() {
  add_nvidia_machine "$OLD_KVER" "$NEW_KVER"
  kernel_state "$OLD_KVER" module nvidia-initramfs
  rm -f "$work/initramfs.stale-options"
  : >"$FAKE_LOG"
}

# promote_refuses DESCRIPTION: the kernel stays out of the default.
promote_refuses() {
  if promote "$NEW_KVER"; then die "$1: the kernel was promoted"; fi
  [[ "$(default_kernel)" == "$OLD_KVER" ]] || die "$1: the default changed to $(default_kernel)"
  grep -q '^grubby --set-default' "$FAKE_LOG" && die "$1: grubby --set-default ran"
  return 0
}

reset; kernel_state "$NEW_KVER" module nvidia-initramfs
promote "$NEW_KVER"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "a kernel with module and initramfs was not promoted: $(default_kernel)"
log "ok: a kernel with the proprietary module and an initramfs carrying nvidia becomes the default"

reset; kernel_state "$NEW_KVER" initramfs
promote_refuses "no module"
grep -q 'nvidia module missing' "$work/err" || die "no module: the reason is not in the error: $(cat "$work/err")"
grep -q 'boot the previous kernel' "$work/err" || die "no module: no way out in the error: $(cat "$work/err")"
reset; kernel_state "$NEW_KVER" open-module nvidia-initramfs
promote_refuses "open module"
grep -q "license 'Dual MIT/GPL'" "$work/err" || die "open module: the reason is not in the error: $(cat "$work/err")"
reset; kernel_state "$NEW_KVER" module initramfs
promote_refuses "initramfs without nvidia"
grep -q 'its initramfs lacks nvidia' "$work/err" || die "initramfs without nvidia: the reason is not in the error: $(cat "$work/err")"
reset; kernel_state "$NEW_KVER" module nvidia-initramfs; touch "$work/initramfs.stale-options"
promote_refuses "initramfs with stale options"
grep -q 'lacks /etc/modprobe.d/vekrona-nvidia.conf' "$work/err" || die "stale options: the reason is not in the error: $(cat "$work/err")"
reset; kernel_state "$NEW_KVER" module
promote_refuses "no initramfs"
grep -q 'lsinitrd failed' "$work/err" || die "no initramfs: the reason is not in the error: $(cat "$work/err")"
reset; kernel_state "$NEW_KVER" module nvidia-initramfs; rm "$work/sysroot/boot/vmlinuz-$NEW_KVER"
if promote "$NEW_KVER"; then die "a kernel that grubby does not know was promoted"; fi
grep -q 'grubby --set-default failed' "$work/err" || die "a failing grubby is not in the error: $(cat "$work/err")"
[[ "$(default_kernel)" == "$OLD_KVER" ]] || die "the default changed to $(default_kernel)"
log "ok: a kernel without a proprietary module, without nvidia or its options in the initramfs, or unknown to grubby never becomes the default"

# The caller is a regular user and root() reaches root through sudo, as install.sh does. On Fedora /boot/loader/entries is 0700 root,
# so the entries directory is closed to the caller (the stand-in for root owns it and passes through the closed mode).
skip_as_root "the entries directory is closed to a regular user"
require_user_namespaces
entries="$work/sysroot/boot/loader/entries"
mkdir "$work/sudo-bin"
printf '#!/usr/bin/env bash\nexec unshare -r "$@"\n' >"$work/sudo-bin/sudo"
chmod +x "$work/sudo-bin/sudo"
default_entry_exists() {
  local status=0
  chmod 000 "$entries"
  PATH="$work/sudo-bin:$PATH" bash -c 'source "$1"; default_boot_entry_exists' _ "$COMMON" 2>"$work/err" || status=$?
  chmod 700 "$entries"
  return "$status"
}
rm -f "$work/saved-entry"
if default_entry_exists; then die "a grubenv without saved_entry counted as an existing default entry"; fi
echo "abc-$OLD_KVER" >"$work/saved-entry"
if default_entry_exists; then die "a saved_entry without its entry file counted as existing"; fi
touch "$entries/abc-$OLD_KVER.conf"
default_entry_exists || die "a saved_entry with its entry file did not count as existing: $(cat "$work/err")"
rm "$entries/abc-$OLD_KVER.conf"
if default_entry_exists; then die "a saved_entry whose kernel was pruned counted as existing"; fi
log "ok: the default boot entry exists only while its entry file does, so a pruned default kernel is noticed, and root sees it in a directory closed to the caller"
