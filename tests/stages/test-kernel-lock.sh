#!/usr/bin/env bash
# Every pass that rebuilds an initramfs, or reads one to decide about the GRUB default, takes the kernel lock: stages, the
# akmods drop-ins and an update's own pass would otherwise run dracut on the same image at once.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
holder=""
cleanup() {
  [[ -z "$holder" ]] || kill "$holder" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
make_world "$work"

COMMON="$REPO/lib/common.sh"
OLD_KVER=7.2.9-200.fc44.x86_64 NEW_KVER=7.2.10-200.fc44.x86_64
locked() { KERNEL_LOCK_WAIT_SECONDS=1 run_as_root bash -c 'source "$1"; shift; "$@"' _ "$COMMON" "$@" 2>"$work/err"; }

reset() {
  add_nvidia_machine "$OLD_KVER" "$NEW_KVER"
  kernel_state "$OLD_KVER" module nvidia-initramfs
  kernel_state "$NEW_KVER" "$@"
  : >"$FAKE_LOG"
}

# Runs "$@" while another process holds the kernel lock; it must give up on the lock, without having touched the image or the default.
refuses_while_held() {
  local description="$1"
  shift
  mkfifo "$work/held" "$work/unlock"
  flock "$work/kernel.lock" bash -c 'echo held >"$1"; read -r <"$2"' _ "$work/held" "$work/unlock" &
  holder=$!
  read -r <"$work/held"
  if locked "$@"; then die "$description ran while another process held the kernel lock"; fi
  echo go >"$work/unlock"
  wait "$holder"
  holder=""
  rm -f "$work/held" "$work/unlock"
  grep -q 'timed out after 1 s waiting for the kernel lock' "$work/err" || die "$description: no lock timeout in the error: $(cat "$work/err")"
  if grep -q '^dracut\|^grubby --set-default' "$FAKE_LOG"; then die "$description changed the image or the default without the lock: $(cat "$FAKE_LOG")"; fi
  log "ok: $description waits for the kernel lock"
}

reset module initramfs
refuses_while_held "ensure_nvidia_initramfs" ensure_nvidia_initramfs "$NEW_KVER"
reset module nvidia-initramfs
refuses_while_held "promote_kernel_if_nvidia_ready" promote_kernel_if_nvidia_ready "$NEW_KVER"
reset module initramfs
refuses_while_held "dracut_locked (stage 45's rebuild, stage 40's regenerate-all)" dracut_locked -f --kver "$NEW_KVER"

reset module initramfs
locked ensure_nvidia_initramfs "$NEW_KVER"
grep -qx "dracut -f --kver $NEW_KVER" "$FAKE_LOG" || die "an unheld lock kept the initramfs from being rebuilt: $(cat "$FAKE_LOG")"
reset module nvidia-initramfs
locked promote_kernel_if_nvidia_ready "$NEW_KVER"
[[ "$(<"$work/default-kernel")" == "$NEW_KVER" ]] || die "an unheld lock kept the kernel from being promoted"
log "ok: with nobody holding the lock the passes run as before"

# A locked pass that calls another locked pass (ensure_nvidia_initramfs inside ensure_kernel_boots_with_nvidia) must not wait for itself.
locked with_kernel_lock with_kernel_lock true || die "a nested with_kernel_lock waited for the lock its caller holds: $(cat "$work/err")"
reset module initramfs
locked ensure_kernel_boots_with_nvidia "$NEW_KVER"
[[ "$(<"$work/default-kernel")" == "$NEW_KVER" ]] || die "ensure_kernel_boots_with_nvidia did not finish"
log "ok: the lock can be taken again by the pass that holds it"

# errexit stays effective inside the locked pass: a failing command ends it instead of being skipped.
out="$(run_as_root bash -c 'set -e; source "$1"; step() { false; echo not-reached; }; with_kernel_lock step; echo after' _ "$COMMON" 2>&1 || true)"
[[ "$out" != *not-reached* && "$out" != *after* ]] || die "a failing step inside the locked pass did not stop it: $out"
log "ok: a failing step inside the lock ends the pass"

rm -f "$work/kernel.lock"
locked with_kernel_lock true || die "a missing lock file was not created: $(cat "$work/err")"
[[ -e "$work/kernel.lock" ]] || die "the lock file was not created"
log "ok: the lock file is created when it is missing"
