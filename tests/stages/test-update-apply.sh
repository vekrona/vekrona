#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
MARKER="$VEKRONA_STATE_DIR/offline-pending"

apply() { run_as_root "$REPO/libexec/vekrona-update-apply" "$@" 2>"$work/err"; }
reset() {
  rm -f "$MARKER" "$VEKRONA_STATE_DIR"/updates.json "$work/offline.empty" "$work/proton.fails"
  echo "No offline transaction is stored." >"$work/offline.status"
  echo 0 >"$work/dnf.rc"; echo 0 >"$work/upgrade.rc"
  # What the 1Password RPM's %post leaves behind.
  sed 's/^repo_gpgcheck=1/repo_gpgcheck=0/' "$REPO/etc/yum.repos.d/1password.repo" >"$work/repos/1password.repo"
  : >"$FAKE_LOG"
  : >"$work/packages"; echo 0 >"$work/akmods.rc"; echo 0 >"$work/dracut.rc"; rm -f "$work/dracut.nonvidia"
}
# True when the log has these lines in this order (other lines may lie between them).
in_order() {
  local from=1 pattern line
  for pattern in "$@"; do
    line="$(tail -n "+$from" "$FAKE_LOG" | grep -n -m1 -- "$pattern" | cut -d: -f1)" || die "'$pattern' is missing or out of order in: $(cat "$FAKE_LOG")"
    from=$((from + line))
  done
}
not_in_log() { if grep -q -- "$1" "$FAKE_LOG"; then die "unexpected '$1' in: $(cat "$FAKE_LOG")"; fi; }

reset
apply --online
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^dnf5 upgrade --refresh -y$' '^flatpak update --system -y --noninteractive$' \
  '^snapper .*--pre-number 10' '^dnf5 check-upgrade --refresh --json$'
not_in_log 'offline'
not_in_log 'without the update lock'
cmp -s "$work/repos/1password.repo" "$REPO/etc/yum.repos.d/1password.repo" || die "the 1Password repo file was not repaired after dnf"
[[ -f "$VEKRONA_STATE_DIR/updates.json" ]] || die "the online run did not rewrite updates.json"
[[ ! -e "$MARKER" ]] || die "an online run left the offline marker"
log "ok: --online runs the steps in order under the lock, repairs the 1Password repo file and rewrites updates.json"

reset; touch "$work/proton.fails"
apply --online || die "a failing Proton stage stopped the update: $(cat "$work/err")"
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^dnf5 upgrade --refresh -y$' '^flatpak update --system -y --noninteractive$'
log "ok: a Proton feed that cannot be staged does not hold back the dnf and Flatpak updates"

reset; echo 1 >"$work/upgrade.rc"
if apply --online; then die "a failing dnf upgrade was accepted"; fi
in_order '^dnf5 upgrade' '^snapper .*--pre-number 10'
not_in_log '^flatpak update'
log "ok: a failing dnf stops the run, and the snapshot pair is still closed"

reset; echo 100 >"$work/dnf.rc"
apply --offline
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^flatpak update' '^dnf5 check-upgrade --refresh$' \
  '^dnf5 upgrade --offline -y$' '^dnf5 offline reboot -y$'
not_in_log '^dnf5 upgrade --refresh'
not_in_log '--pre-number'
[[ -s "$MARKER" ]] || die "the offline marker was not written before the reboot"
grep -qx 'pre=10' "$MARKER" || die "the marker does not name the pre snapshot, so vekrona-update-post cannot close the pair: $(cat "$MARKER")"
log "ok: --offline updates Flatpak first, stores dnf's transaction, takes no post snapshot before the transaction ran, hands the pre snapshot to the next boot in the marker and reboots"

reset; echo 100 >"$work/dnf.rc"
apply --offline --poweroff
in_order '^dnf5 offline reboot -y --poweroff$'
log "ok: --offline --poweroff powers off after the update"

reset
apply --offline
in_order '^flatpak update' '^dnf5 check-upgrade --refresh$' '^dnf5 check-upgrade --refresh --json$'
not_in_log '^dnf5 upgrade --\(offline\|refresh\)'
not_in_log 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written with no transaction stored"
log "ok: with nothing for dnf, Flatpak runs and the machine does not reboot"

reset; echo 100 >"$work/dnf.rc"; touch "$work/offline.empty"
apply --offline
in_order '^dnf5 upgrade --offline -y$'
not_in_log 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written although dnf stored no transaction"
log "ok: updates dnf lists but cannot install store nothing, so the machine does not reboot for them"

reset; echo 7 >"$work/dnf.rc"
if apply --offline; then die "a failing dnf check-upgrade was accepted"; fi
not_in_log 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written after a failed check-upgrade"
log "ok: a dnf failure before the transaction is stored fails the run without a reboot"

for args in "" "--poweroff" "--online --poweroff" "--offline --online" "--sideways"; do
  # shellcheck disable=SC2086
  if apply $args; then die "accepted the arguments '$args'"; fi
  grep -q '^usage:' "$work/err" || die "no usage for '$args': $(cat "$work/err")"
done
log "ok: unknown or mixed arguments print the usage"

if "$REPO/libexec/vekrona-update-apply" --online 2>"$work/err"; then die "ran as a regular user"; fi
grep -q 'must run as root' "$work/err" || die "no root requirement error: $(cat "$work/err")"
log "ok: a regular user is refused"

OLD_KVER=7.2.9-200.fc44.x86_64 NEW_KVER=7.2.10-200.fc44.x86_64
nvidia_apply() { reset; add_nvidia_machine "$OLD_KVER" "$NEW_KVER"; }
default_kernel() { cat "$work/default-kernel"; }

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module nvidia-initramfs
apply --online
not_in_log '^akmods'; not_in_log '^dracut'
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "a ready newest kernel did not become the default: $(default_kernel)"
log "ok: a newest kernel that is ready is left alone and becomes the default"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module initramfs
apply --online
in_order "^dracut -f --kver $NEW_KVER\$"
not_in_log '^akmods'; not_in_log "dracut.*$OLD_KVER"
grep -q nvidia.ko "$work/sysroot/boot/initramfs-$NEW_KVER.img" || die "the new kernel's initramfs still lacks nvidia"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "the regenerated kernel did not become the default: $(default_kernel)"
log "ok: an initramfs without nvidia is regenerated for the newest kernel only, which then becomes the default"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs
apply --online
in_order "^akmods --force --kernels $NEW_KVER\$" "^dracut -f --kver $NEW_KVER\$" "^grubby --set-default /boot/vmlinuz-$NEW_KVER\$"
log "ok: a missing module is built before the initramfs is regenerated and the kernel promoted"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs; echo 1 >"$work/akmods.rc"
if apply --online; then die "an akmods build failure for the newest kernel was accepted"; fi
grep -q "boot the previous kernel" "$work/err" || die "no way out in the error: $(cat "$work/err")"
not_in_log '^dracut'; not_in_log '^grubby --set-default'
[[ "$(default_kernel)" == "$OLD_KVER" ]] || die "a kernel whose build failed became the default: $(default_kernel)"
in_order '^snapper .*--pre-number 10'
log "ok: a failed akmods build fails the run with the way out, the previous kernel stays the default, and the snapshot pair is still closed"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module initramfs; touch "$work/dracut.nonvidia"
if apply --online; then die "an initramfs still lacking nvidia after dracut was accepted"; fi
grep -q "still lacks nvidia" "$work/err" || die "no initramfs error: $(cat "$work/err")"
[[ "$(default_kernel)" == "$OLD_KVER" ]] || die "a kernel with an initramfs lacking nvidia became the default: $(default_kernel)"
log "ok: an initramfs that dracut leaves without nvidia fails the run and the previous kernel stays the default"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module nvidia-initramfs; touch "$work/initramfs.stale-options"
if apply --online; then die "an up-to-date initramfs with stale modprobe options was accepted"; fi
rm -f "$work/initramfs.stale-options"
grep -q "lacks /etc/modprobe.d/vekrona-nvidia.conf" "$work/err" || die "no options error: $(cat "$work/err")"
not_in_log '^grubby --set-default'
[[ "$(default_kernel)" == "$OLD_KVER" ]] || die "a kernel whose initramfs carries stale options became the default: $(default_kernel)"
log "ok: an up-to-date initramfs whose packed modprobe options are stale is refused and never promoted"

nvidia_apply; : >"$work/packages"; kernel_state "$OLD_KVER" initramfs; kernel_state "$NEW_KVER" initramfs
apply --online
not_in_log '^akmods'; not_in_log '^dracut'
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "without akmod-nvidia the newest kernel did not become the default: $(default_kernel)"
log "ok: without akmod-nvidia the newest kernel becomes the default and no module is built"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module nvidia-initramfs
apply --online
[[ "$(log_lines "^lsinitrd .*initramfs-$NEW_KVER.img")" -eq 2 ]] \
  || die "the new kernel's initramfs was not read exactly twice (once for nvidia, once for its options): $(cat "$FAKE_LOG")"
log "ok: an update reads the new kernel's initramfs only to verify nvidia and its options, once each"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs
apply --offline
not_in_log '^akmods'; not_in_log '^dracut'; not_in_log '^grubby'
log "ok: --offline leaves the initramfs and the default kernel to the boot that installs the kernel"
