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
  rm -f "$MARKER" "$VEKRONA_STATE_DIR"/updates.json "$work/offline.empty"
  echo "No offline transaction is stored." >"$work/offline.status"
  echo 0 >"$work/dnf.rc"; echo 0 >"$work/upgrade.rc"
  # What the 1Password RPM's %post leaves behind.
  sed 's/^repo_gpgcheck=1/repo_gpgcheck=0/' "$REPO/etc/yum.repos.d/1password.repo" >"$work/repos/1password.repo"
  : >"$FAKE_LOG"
  : >"$work/packages"; echo 0 >"$work/akmods.rc"; echo 0 >"$work/dracut.rc"; rm -f "$work/dracut.nonvidia"
  rm -f "$work/mise.warns"
}
# True when the log has these lines in this order (other lines may lie between them).
in_order() {
  local from=1 pattern line
  for pattern in "$@"; do
    line="$(tail -n "+$from" "$FAKE_LOG" | grep -n -m1 -- "$pattern" | cut -d: -f1)" || die "'$pattern' is missing or out of order in: $(cat "$FAKE_LOG")"
    from=$((from + line))
  done
}
absent() { if grep -q -- "$1" "$FAKE_LOG"; then die "unexpected '$1' in: $(cat "$FAKE_LOG")"; fi; }

reset
apply --online
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^dnf5 upgrade --refresh -y$' '^flatpak update --system -y --noninteractive$' \
  '^mise upgrade --dry-run$' '^mise upgrade$' '^mise prune' '^mise reshim$' '^snapper .*--pre-number 10' '^dnf5 check-upgrade --refresh --json$'
absent 'offline'
absent 'without the update lock'
cmp -s "$work/repos/1password.repo" "$REPO/etc/yum.repos.d/1password.repo" || die "the 1Password repo file was not repaired after dnf"
[[ -f "$VEKRONA_STATE_DIR/updates.json" ]] || die "the online run did not rewrite updates.json"
[[ ! -e "$MARKER" ]] || die "an online run left the offline marker"
log "ok: --online runs the steps in order under the lock, repairs the 1Password repo file and rewrites updates.json"

reset; echo 1 >"$work/upgrade.rc"
if apply --online; then die "a failing dnf upgrade was accepted"; fi
in_order '^dnf5 upgrade' '^snapper .*--pre-number 10'
absent '^flatpak update'
log "ok: a failing dnf stops the run, and the snapshot pair is still closed"

reset; echo 100 >"$work/dnf.rc"
apply --offline
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^flatpak update' '^mise upgrade$' '^dnf5 check-upgrade --refresh$' \
  '^dnf5 upgrade --offline -y$' '^snapper .*--pre-number 10' '^dnf5 offline reboot -y$'
absent '^dnf5 upgrade --refresh'
[[ -s "$MARKER" ]] || die "the offline marker was not written before the reboot"
log "ok: --offline updates Flatpak and mise first, stores dnf's transaction, closes the snapshot pair, writes the marker and reboots"

reset; echo 100 >"$work/dnf.rc"
apply --offline --poweroff
in_order '^dnf5 offline reboot -y --poweroff$'
log "ok: --offline --poweroff powers off after the update"

reset
apply --offline
in_order '^flatpak update' '^mise upgrade$' '^dnf5 check-upgrade --refresh$' '^dnf5 check-upgrade --refresh --json$'
absent 'dnf5 upgrade'
absent 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written with no transaction stored"
log "ok: with nothing for dnf, Flatpak and mise run and the machine does not reboot"

reset; echo 100 >"$work/dnf.rc"; touch "$work/offline.empty"
apply --offline
in_order '^dnf5 upgrade --offline -y$'
absent 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written although dnf stored no transaction"
log "ok: updates dnf lists but cannot install store nothing, so the machine does not reboot for them"

reset; echo 7 >"$work/dnf.rc"
if apply --offline; then die "a failing dnf check-upgrade was accepted"; fi
absent 'offline reboot'
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

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module nvidia-initramfs
apply --online
absent '^akmods'; absent '^dracut'
log "ok: a newest kernel whose initramfs carries nvidia is left alone"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module initramfs
apply --online
in_order "^dracut -f --kver $NEW_KVER\$"
absent '^akmods'; absent "dracut.*$OLD_KVER"
grep -q nvidia.ko "$work/sysroot/boot/initramfs-$NEW_KVER.img" || die "the new kernel's initramfs still lacks nvidia"
log "ok: an initramfs without nvidia is regenerated for the newest kernel only"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs
apply --online
in_order "^akmods --rebuild --kernels $NEW_KVER\$" "^dracut -f --kver $NEW_KVER\$"
log "ok: a missing module is built before the initramfs is regenerated"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs; echo 1 >"$work/akmods.rc"
if apply --online; then die "an akmods build failure for the newest kernel was accepted"; fi
grep -q "boot the previous kernel" "$work/err" || die "no way out in the error: $(cat "$work/err")"
absent '^dracut'
in_order '^snapper .*--pre-number 10'
log "ok: a failed akmods build fails the run with the way out, and the snapshot pair is still closed"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module initramfs; touch "$work/dracut.nonvidia"
if apply --online; then die "an initramfs still lacking nvidia after dracut was accepted"; fi
grep -q "still lacks nvidia" "$work/err" || die "no initramfs error: $(cat "$work/err")"
log "ok: an initramfs that dracut leaves without nvidia fails the run"

reset; kernel_state "$OLD_KVER" initramfs
echo "$OLD_KVER" >"$work/kernels"
apply --online
absent '^akmods'; absent '^dracut'
log "ok: without akmod-nvidia the kernels are left alone"

nvidia_apply; kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs
apply --offline
absent '^akmods'; absent '^dracut'
log "ok: --offline leaves the initramfs to the boot that installs the kernel"

reset; touch "$work/mise.warns"
if apply --online; then die "mise lookups that failed with a zero exit status were accepted"; fi
grep -q 'could not look up the latest versions' "$work/err" || die "no mise error: $(cat "$work/err")"
log "ok: mise warnings about failed version lookups fail the run although mise exits 0"
