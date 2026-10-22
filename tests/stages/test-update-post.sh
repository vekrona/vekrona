#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
MARKER="$VEKRONA_STATE_DIR/offline-pending"
JSON="$VEKRONA_STATE_DIR/updates.json"

post() { run_as_root "$REPO/libexec/vekrona-update-post" 2>"$work/err"; }
reset() {
  { date -Iseconds; echo pre=10; } >"$MARKER"
  echo '{"pending": true}' >"$JSON"
  echo "No offline transaction is stored." >"$work/offline.status"
  rm -f "$work"/sessions/* "$work/notify.fails"
  sed 's/^repo_gpgcheck=1/repo_gpgcheck=0/' "$REPO/etc/yum.repos.d/1password.repo" >"$work/repos/1password.repo"
  : >"$FAKE_LOG"
  : >"$work/packages"; echo 0 >"$work/akmods.rc"; echo 0 >"$work/dracut.rc"
  rm -f "$work/akmods.builds-nothing" "$work/dracut.nonvidia"
}

reset; add_session 1
post
[[ "$(jq .pending "$JSON")" == false ]] || die "updates.json still says pending after the update: $(cat "$JSON")"
cmp -s "$work/repos/1password.repo" "$REPO/etc/yum.repos.d/1password.repo" || die "the 1Password repo file was not repaired"
grep -q 'runuser -u someone -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus notify-send -a vekrona .*System updated' "$FAKE_LOG" \
  || die "the user was not told: $(cat "$FAKE_LOG")"
[[ ! -e "$MARKER" ]] || die "the marker survived"
log "ok: a finished offline update repairs the repo file, rewrites updates.json, tells the user and removes the marker"
grep -q '^snapper .*create .*--pre-number 10' "$FAKE_LOG" || die "the post snapshot of the pre snapshot named by the marker was not taken after the update: $(cat "$FAKE_LOG")"
log "ok: the post snapshot is taken after the offline transaction ran, paired with the pre snapshot the marker names"

reset
echo "not-a-marker" >"$MARKER"
post
grep -q 'names no pre-update snapshot' "$work/err" || die "a marker without a pre snapshot was not reported: $(cat "$work/err")"
grep -q -- '--pre-number' "$FAKE_LOG" && die "a post snapshot was taken without a pre snapshot to pair it with"
[[ ! -e "$MARKER" ]] || die "the marker survived"
log "ok: a marker without a pre snapshot is reported and the update still finishes"

reset
post
grep -q '^runuser' "$FAKE_LOG" && die "notified with nobody logged in"
[[ ! -e "$MARKER" ]] || die "the marker survived"
log "ok: with nobody logged in the update still finishes"

reset; add_session 1; touch "$work/notify.fails"
if post; then die "a failing notification was ignored"; fi
[[ ! -e "$MARKER" ]] || die "the marker survived a failed notification"
log "ok: a notification that fails is an error"

for status in "An offline transaction was started, but it did not finish. Run \`dnf5 offline log\` for more information." \
  "An offline transaction was initiated by the following command: dnf5 upgrade --offline"; do
  reset; add_session 1
  echo "$status" >"$work/offline.status"
  if post; then die "a transaction still stored was taken as finished: $status"; fi
  grep -q "did not finish: $status" "$work/err" || die "the status is not in the error: $(cat "$work/err")"
  grep -q 'offline log line' "$work/err" || die "the dnf log is not in the error: $(cat "$work/err")"
  [[ ! -e "$MARKER" ]] || die "the marker survived a failed update"
  [[ "$(jq .pending "$JSON")" == false ]] || die "updates.json was not refreshed after a failed update"
  grep -q 'notify-send' "$FAKE_LOG" && die "reported a failed update as updated"
done
log "ok: a transaction dnf still holds fails the unit with dnf's status and log, and updates.json is refreshed"

reset; rm "$MARKER"
if post; then die "ran without the marker"; fi
grep -q 'no offline update is pending' "$work/err" || die "no marker error: $(cat "$work/err")"
log "ok: without the marker there is nothing to report"

OLD_KVER=7.2.9-200.fc44.x86_64 NEW_KVER=7.2.10-200.fc44.x86_64
reset; add_session 1; add_nvidia_machine "$OLD_KVER" "$NEW_KVER"
kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" module initramfs
post
grep -q "^dracut -f --kver $NEW_KVER\$" "$FAKE_LOG" || die "the new kernel's initramfs was not regenerated: $(cat "$FAKE_LOG")"
log "ok: an offline update that left the newest kernel's initramfs without nvidia regenerates it"

reset; add_session 1; add_nvidia_machine "$OLD_KVER" "$NEW_KVER"
kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" initramfs; echo 1 >"$work/akmods.rc"
if post; then die "an akmods build failure for the newest kernel was accepted"; fi
grep -q 'boot the previous kernel' "$work/err" || die "no way out in the error: $(cat "$work/err")"
grep -q 'notify-send' "$FAKE_LOG" && die "reported an update as installed although the newest kernel cannot show the display"
log "ok: a failed akmods build after an offline update fails the unit instead of announcing success"

default_kernel() { cat "$work/default-kernel"; }

# A newest kernel the offline update installed in the state given by the arguments (kernel_state keys), next to an old
# kernel that is ready and the default.
offline_update_brought_kernel() {
  reset; add_session 1; add_nvidia_machine "$OLD_KVER" "$NEW_KVER"
  kernel_state "$OLD_KVER" module nvidia-initramfs; kernel_state "$NEW_KVER" "$@"
}

offline_update_brought_kernel initramfs
post
grep -qx "akmods --force --kernels $NEW_KVER" "$FAKE_LOG" || die "the missing module was not built with plain akmods: $(cat "$FAKE_LOG")"
grep -q -- '--rebuild' "$FAKE_LOG" && die "akmods --rebuild was used for a kmod that was never installed: $(cat "$FAKE_LOG")"
grep -q nvidia.ko "$work/sysroot/boot/initramfs-$NEW_KVER.img" || die "the new kernel's initramfs lacks nvidia"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "the new kernel did not become the default: $(default_kernel)"
grep -q 'notify-send' "$FAKE_LOG" || die "the user was not told: $(cat "$FAKE_LOG")"
log "ok: after an offline update that brought a kernel without a kmod, the post step installs the module, puts nvidia in its initramfs, and makes it the default"

# assert_new_kernel_stays_out DESCRIPTION AKMODS_LINE: the post step fails with the way out, the old kernel stays the
# default, and akmods (when it ran, AKMODS_LINE is its command line) got the arguments the kmod's install state calls for.
assert_new_kernel_stays_out() {
  if post; then die "$1: the post step succeeded"; fi
  grep -q 'boot the previous kernel' "$work/err" || die "$1: no way out in the error: $(cat "$work/err")"
  [[ "$(default_kernel)" == "$OLD_KVER" ]] || die "$1: the kernel became the default: $(default_kernel)"
  grep -q '^grubby --set-default' "$FAKE_LOG" && die "$1: the default kernel was set: $(cat "$FAKE_LOG")"
  grep -q 'notify-send' "$FAKE_LOG" && die "$1: reported the update as installed"
  [[ -z "${2:-}" ]] || grep -qx "$2" "$FAKE_LOG" || die "$1: akmods was not run as '$2': $(cat "$FAKE_LOG")"
  return 0
}

offline_update_brought_kernel initramfs; touch "$work/akmods.builds-nothing"
assert_new_kernel_stays_out "akmods exits 0 and builds no module" "akmods --force --kernels $NEW_KVER"
offline_update_brought_kernel initramfs; echo 1 >"$work/akmods.rc"
assert_new_kernel_stays_out "akmods exits non-zero" "akmods --force --kernels $NEW_KVER"
offline_update_brought_kernel open-module initramfs; echo 1 >"$work/akmods.rc"
assert_new_kernel_stays_out "the rebuild of an open module fails" "akmods --rebuild --force --kernels $NEW_KVER"
offline_update_brought_kernel module; echo 1 >"$work/dracut.rc"
assert_new_kernel_stays_out "the initramfs is missing and dracut fails"
offline_update_brought_kernel module initramfs; touch "$work/dracut.nonvidia"
assert_new_kernel_stays_out "dracut leaves nvidia out of the initramfs"
log "ok: a kernel whose module cannot be built never becomes the default, and the post step fails"

offline_update_brought_kernel open-module initramfs
post
grep -qx "akmods --rebuild --force --kernels $NEW_KVER" "$FAKE_LOG" || die "the open module was not rebuilt with --rebuild: $(cat "$FAKE_LOG")"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "the kernel with the rebuilt module did not become the default: $(default_kernel)"
log "ok: a kernel with an open-licensed module is rebuilt with --rebuild"

offline_update_brought_kernel initramfs failed-build
post
grep -qx "akmods --force --kernels $NEW_KVER" "$FAKE_LOG" || die "akmods was not forced past the failed build log: $(cat "$FAKE_LOG")"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "a kernel whose earlier build failed did not become the default: $(default_kernel)"
log "ok: a build that failed earlier is retried"

offline_update_brought_kernel initramfs; echo 1 >"$work/akmods.rc"
if post; then die "a failing build was accepted"; fi
[[ -e "$MARKER" ]] || die "the marker was removed although the new kernel is not ready, so no later boot retries"
echo 0 >"$work/akmods.rc"
post
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "the retry did not promote the kernel: $(default_kernel)"
[[ ! -e "$MARKER" ]] || die "the marker survived the successful retry"
grep -q 'notify-send' "$FAKE_LOG" || die "the retry did not tell the user: $(cat "$FAKE_LOG")"
log "ok: a post step that cannot ready the new kernel keeps its marker, and the next boot retries and promotes it"

# The update check needs the network, which the first boot after an update may not have yet. The newest kernel must not
# wait for it, and the marker must not stay for a kernel that is ready.
offline_update_brought_kernel initramfs; echo 7 >"$work/dnf.rc"
if post; then die "a failing update check was accepted"; fi
echo 0 >"$work/dnf.rc"
[[ "$(default_kernel)" == "$NEW_KVER" ]] || die "a failing update check kept the new kernel from becoming the default: $(default_kernel)"
grep -q 'notify-send' "$FAKE_LOG" || die "a failing update check kept the user from being told: $(cat "$FAKE_LOG")"
[[ ! -e "$MARKER" ]] || die "the marker survived although the kernel is ready: the next boot would repeat a finished update"
grep -q 'dnf5 check-upgrade failed' "$work/err" || die "the failing check is not in the error: $(cat "$work/err")"
log "ok: a failing update check still promotes the kernel, tells the user and clears the marker, and fails the unit"

reset; add_session 1
echo "An offline transaction was started, but it did not finish." >"$work/offline.status"; echo 7 >"$work/dnf.rc"
if post; then die "an unfinished transaction plus a failing check was accepted"; fi
echo 0 >"$work/dnf.rc"
grep -q 'did not finish' "$work/err" || die "the check failure hid the unfinished transaction: $(cat "$work/err")"
log "ok: an unfinished offline transaction is reported even when the check fails too"
