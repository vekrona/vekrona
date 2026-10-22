#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
holder="" ready=""
# A failed run leaves the lock holder blocked on its fifo; killing a process that already exited fails, which is fine.
cleanup() {
  local pid
  for pid in "$holder" "$ready"; do [[ -z "$pid" ]] || kill "$pid" 2> /dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT
make_world "$work"

WAIT_LIMIT_SEC=30
ANCIENT_KVER=7.2.8-200.fc44.x86_64 OLD_KVER=7.2.9-200.fc44.x86_64 NEW_KVER=7.2.10-200.fc44.x86_64

default_kernel() { cat "$work/default-kernel"; }
kernel_ready() { run_as_root "$REPO/libexec/vekrona-kernel-ready" "$@" 2>"$work/err"; }
# The akmods@ build succeeded for NEW_KVER, which kernel-install gave an initramfs before the module existed; the
# ancient kernel is the default.
reset() {
  add_nvidia_machine "$ANCIENT_KVER" "$OLD_KVER" "$NEW_KVER"
  kernel_state "$ANCIENT_KVER" module nvidia-initramfs
  kernel_state "$OLD_KVER" module nvidia-initramfs
  kernel_state "$NEW_KVER" module initramfs
  rm -f "$work/akmods.builds-nothing"
  : >"$FAKE_LOG"
}

reset
kernel_ready "$NEW_KVER"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "the newest kernel was not promoted: $(default_kernel)"
grep -q nvidia.ko "$work/sysroot/boot/initramfs-$NEW_KVER.img" || die "the newest kernel's initramfs lacks nvidia"
log "ok: after its kmod build the newest kernel gets nvidia in its initramfs and becomes the default"

reset; kernel_state "$OLD_KVER" module initramfs
kernel_ready "$OLD_KVER"
grep -q nvidia.ko "$work/sysroot/boot/initramfs-$OLD_KVER.img" || die "the older kernel's initramfs lacks nvidia"
[[ "$(default_kernel)" == "$ANCIENT_KVER" ]] || die "an older kernel took the default: $(default_kernel)"
log "ok: an older kernel gets its initramfs but never takes the default from the newest"

reset; kernel_state "$NEW_KVER" initramfs; touch "$work/akmods.builds-nothing"
if kernel_ready "$NEW_KVER"; then die "a newest kernel without a module was accepted"; fi
grep -q 'boot the previous kernel' "$work/err" || die "no way out in the error: $(cat "$work/err")"
[[ "$(default_kernel)" == "$ANCIENT_KVER" ]] || die "a kernel without a module became the default: $(default_kernel)"
log "ok: a newest kernel that still has no module fails and stays out of the default"

for args in "" "$NEW_KVER $OLD_KVER"; do
  # shellcheck disable=SC2086
  if kernel_ready $args; then die "accepted the arguments '$args'"; fi
  grep -q '^usage:' "$work/err" || die "no usage for '$args': $(cat "$work/err")"
done
log "ok: anything but one kernel version prints the usage"

if "$REPO/libexec/vekrona-kernel-ready" "$NEW_KVER" 2>"$work/err"; then die "ran as a regular user"; fi
grep -q 'must run as root' "$work/err" || die "no root requirement error: $(cat "$work/err")"
log "ok: a regular user is refused"

# Another process (an update's own pass over the same kernel) holds the kernel lock: kernel-ready must not run dracut
# until it is released.
mkfifo "$work/held" "$work/unlock"
reset
flock "$work/kernel.lock" bash -c 'echo held >"$1"; read -r <"$2"' _ "$work/held" "$work/unlock" &
holder=$!
read -r <"$work/held"
kernel_ready "$NEW_KVER" &
ready=$!
# kernel-ready has either reached its flock or ended. Back-to-back looks, but bounded: a kernel-ready that does neither must fail.
waiting_for_lock_or_done() { pgrep -f '^flock -w [0-9]+ [0-9]+$' >/dev/null || ! kill -0 "$ready" 2>/dev/null; }
wait_until "$WAIT_LIMIT_SEC" waiting_for_lock_or_done || die "kernel-ready neither waited for the kernel lock nor ended within $WAIT_LIMIT_SEC s"
kill -0 "$ready" 2>/dev/null || die "kernel-ready finished while another process held the kernel lock"
grep -q '^dracut' "$FAKE_LOG" && die "kernel-ready ran dracut while another process held the kernel lock"
echo go >"$work/unlock"
wait "$holder"
wait "$ready"
grep -q "^dracut -f --kver $NEW_KVER\$" "$FAKE_LOG" || die "kernel-ready did not run dracut once the lock was released: $(cat "$FAKE_LOG")"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "the newest kernel was not promoted after the lock was released: $(default_kernel)"
log "ok: regenerating the initramfs and promoting wait for whoever else holds the kernel lock"

# A holder that never lets go fails the waiter instead of hanging it.
reset
flock "$work/kernel.lock" bash -c 'echo held >"$1"; read -r <"$2"' _ "$work/held" "$work/unlock" &
holder=$!
read -r <"$work/held"
if KERNEL_LOCK_WAIT_SECONDS=1 kernel_ready "$NEW_KVER"; then die "kernel-ready ran while another process held the kernel lock"; fi
echo go >"$work/unlock"
wait "$holder"
grep -q 'timed out after 1 s waiting for the kernel lock' "$work/err" || die "no timeout error: $(cat "$work/err")"
grep -q '^dracut' "$FAKE_LOG" && die "kernel-ready ran dracut without the kernel lock"
log "ok: a kernel lock that stays held fails the waiter with a timeout instead of hanging"
