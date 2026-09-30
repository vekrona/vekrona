#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <test.iso>" >&2
  exit 1
}

[[ $# -eq 1 ]] || usage
TEST_ISO="$1"
[[ -r "$TEST_ISO" ]] || { echo "test ISO not readable: $TEST_ISO" >&2; exit 1; }

ISO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log()  { printf '[qemu-test] %s\n' "$*" >&2; }
fail() { printf '[qemu-test] FAILED: %s\n' "$*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || fail "qemu-system-x86_64 not installed"
command -v qemu-img >/dev/null 2>&1 || fail "qemu-img not installed"
command -v ssh >/dev/null 2>&1 || fail "ssh not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 not installed (needed to pick a free SSH forwarding port)"
command -v socat >/dev/null 2>&1 || fail "socat not installed (needed to type the LUKS passphrase into the installed disk's serial console)"

[[ -e /dev/kvm ]] || fail "/dev/kvm does not exist; KVM is required (enable virtualization in firmware, load the kvm module, and on CI runners enable nested virtualization)"
[[ -r /dev/kvm && -w /dev/kvm ]] || fail "/dev/kvm exists but is not accessible (permission denied); add this user to the kvm group and re-login, or on CI install the 99-kvm4all udev rule"

RAM_MB="${VEKRONA_QEMU_RAM_MB:-8192}"
VCPUS="${VEKRONA_QEMU_VCPUS:-4}"
DISK_GB="${VEKRONA_QEMU_DISK_GB:-40}"
SSH_KEY="${VEKRONA_TEST_SSH_KEY:-$ISO_DIR/.ssh/id_ed25519}"
DISPLAY_MODE="${VEKRONA_QEMU_DISPLAY:-none}"
VNC_DISPLAY="${VEKRONA_QEMU_VNC_DISPLAY:-0}"
INSTALL_TIMEOUT="${VEKRONA_INSTALL_TIMEOUT:-3600}"
SSH_TIMEOUT="${VEKRONA_SSH_TIMEOUT:-300}"
FIRSTBOOT_TIMEOUT="${VEKRONA_FIRSTBOOT_TIMEOUT:-2400}"
REBOOT_TIMEOUT="${VEKRONA_REBOOT_TIMEOUT:-180}"
POLL_INTERVAL="${VEKRONA_POLL_INTERVAL:-3}"
VM_USER="vekrona"
LUKS_PASSPHRASE="vekrona"

[[ -r "$SSH_KEY" ]] || fail "test SSH private key not readable: $SSH_KEY (set VEKRONA_TEST_SSH_KEY to the private half of the key passed to iso/build.sh --test-ssh-pubkey)"

free_port() {
  python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}
SSH_PORT="${VEKRONA_SSH_PORT:-$(free_port)}"

find_ovmf() {
  local pair code vars
  local candidates=(
    "/usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE_4M.fd:/usr/share/edk2/ovmf/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2-ovmf/OVMF_CODE.fd:/usr/share/edk2-ovmf/OVMF_VARS.fd"
  )
  for pair in "${candidates[@]}"; do
    code="${pair%%:*}"
    vars="${pair##*:}"
    if [[ -r "$code" && -r "$vars" ]]; then
      echo "$code:$vars"
      return 0
    fi
  done
  return 1
}

ovmf_pair="$(find_ovmf)" || fail "could not find OVMF UEFI firmware (looked for OVMF_CODE*.fd + OVMF_VARS*.fd under /usr/share/edk2/ovmf, /usr/share/OVMF and /usr/share/edk2-ovmf); install edk2-ovmf (Fedora) or ovmf (Debian/Ubuntu)"
OVMF_CODE="${ovmf_pair%%:*}"
OVMF_VARS_SRC="${ovmf_pair##*:}"

WORKDIR="$(mktemp -d -t vekrona-qemu-test.XXXXXX)"
DISK_IMG="$WORKDIR/disk.qcow2"
VARS_COPY="$WORKDIR/OVMF_VARS.fd"
cp "$OVMF_VARS_SRC" "$VARS_COPY"

LOG_DIR="${VEKRONA_QEMU_LOG_DIR:-$(mktemp -d -t vekrona-qemu-test-logs.XXXXXX)}"
mkdir -p "$LOG_DIR"
SERIAL_INSTALL_LOG="$LOG_DIR/serial-install.log"
SERIAL_RUN_LOG="$LOG_DIR/serial-run.log"
SERIAL_RUN_SOCK="$WORKDIR/serial-run.sock"
log "serial console logs: $LOG_DIR"

QEMU_PID=""
LUKS_WATCHER_PID=""
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    local f
    for f in "$SERIAL_INSTALL_LOG" "$SERIAL_RUN_LOG"; do
      [[ -e "$f" ]] || continue
      echo "---- serial console log: $f (tail) ----" >&2
      tail -n 200 "$f" >&2 || true
      echo "---- end $f ----" >&2
    done
  fi
  if [[ -n "$LUKS_WATCHER_PID" ]] && kill -0 "$LUKS_WATCHER_PID" 2>/dev/null; then
    kill "$LUKS_WATCHER_PID" 2>/dev/null || true
    wait "$LUKS_WATCHER_PID" 2>/dev/null || true
  fi
  if [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
    kill "$QEMU_PID" 2>/dev/null || true
    wait "$QEMU_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

start_luks_watcher() {
  local log_file="$1" sock="$2"
  until [[ -S "$sock" ]]; do sleep 0.2; done
  tail -n0 -F "$log_file" 2>/dev/null | while IFS= read -r line; do
    [[ "$line" == *"Please enter passphrase"* ]] || continue
    printf '%s\n' "$LUKS_PASSPHRASE" | socat -t2 - "UNIX-CONNECT:$sock" >/dev/null 2>&1 || true
  done &
  LUKS_WATCHER_PID=$!
}

qemu-img create -f qcow2 "$DISK_IMG" "${DISK_GB}G" >/dev/null

common_qemu_args=(
  -enable-kvm
  -machine q35
  -cpu host
  -m "$RAM_MB"
  -smp "$VCPUS"
  -no-user-config
  -nodefaults
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
  -drive "if=pflash,format=raw,file=$VARS_COPY"
  -drive "file=$DISK_IMG,format=qcow2,if=virtio,cache=writeback"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
  -device "virtio-net-pci,netdev=net0"
)
case "$DISPLAY_MODE" in
  none) common_qemu_args+=(-display none) ;;
  vnc) common_qemu_args+=(-display "vnc=127.0.0.1:${VNC_DISPLAY}") ;;
  *) fail "unknown VEKRONA_QEMU_DISPLAY: $DISPLAY_MODE (use 'none' or 'vnc')" ;;
esac

log "phase 1: booting the test ISO to install (ssh forwarded to 127.0.0.1:$SSH_PORT, install timeout ${INSTALL_TIMEOUT}s)"
qemu-system-x86_64 "${common_qemu_args[@]}" \
  -drive "file=$TEST_ISO,media=cdrom,if=ide,readonly=on" \
  -boot order=d,menu=off \
  -serial "file:$SERIAL_INSTALL_LOG" \
  -no-reboot &
QEMU_PID=$!

deadline=$((SECONDS + INSTALL_TIMEOUT))
while kill -0 "$QEMU_PID" 2>/dev/null; do
  (( SECONDS < deadline )) || { kill "$QEMU_PID" 2>/dev/null || true; fail "install did not finish within ${INSTALL_TIMEOUT}s (qemu still running)"; }
  sleep "$POLL_INTERVAL"
done
wait "$QEMU_PID"
install_rc=$?
QEMU_PID=""
[[ $install_rc -eq 0 ]] || fail "qemu exited with status $install_rc during install (expected 0: -no-reboot makes qemu exit cleanly instead of rebooting when Anaconda finishes)"
log "phase 1 done: installer finished and qemu exited"

log "phase 2: booting the installed disk (cdrom detached, LUKS-encrypted root)"
qemu-system-x86_64 "${common_qemu_args[@]}" \
  -boot order=c,menu=off \
  -chardev "socket,id=serial0,path=$SERIAL_RUN_SOCK,server=on,wait=off,logfile=$SERIAL_RUN_LOG" \
  -serial chardev:serial0 &
QEMU_PID=$!
start_luks_watcher "$SERIAL_RUN_LOG" "$SERIAL_RUN_SOCK"

SSH_OPTS=(-F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSH_PORT")
ssh_guest() { ssh "${SSH_OPTS[@]}" "$VM_USER@127.0.0.1" "$@"; }

poll_until() {
  local timeout="$1" desc="$2"; shift 2
  local deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    if [[ -n "$QEMU_PID" ]] && ! kill -0 "$QEMU_PID" 2>/dev/null; then
      fail "qemu process exited unexpectedly while waiting for: $desc"
    fi
    (( SECONDS < deadline )) || fail "timed out after ${timeout}s waiting for: $desc"
    sleep "$POLL_INTERVAL"
  done
}

log "waiting for SSH (timeout ${SSH_TIMEOUT}s)"
poll_until "$SSH_TIMEOUT" "ssh reachable" ssh_guest true

log "checking the installed system: LUKS2 root, wheel membership, locked root, hostname, timezone, no leaked passphrase"
root_source="$(ssh_guest "findmnt -no SOURCE /" | sed 's/\[.*//')"
[[ -n "$root_source" ]] || fail "could not resolve the root filesystem's source device"
root_type="$(ssh_guest "lsblk -no TYPE '$root_source'")"
[[ "$root_type" == "crypt" ]] || fail "root filesystem is not on a LUKS mapper device (lsblk TYPE=$root_type)"
root_pkname="$(ssh_guest "lsblk -no PKNAME '$root_source'")"
[[ -n "$root_pkname" ]] || fail "could not resolve the LUKS mapper device's parent partition"
luks_version="$(ssh_guest "sudo cryptsetup luksDump '/dev/$root_pkname'" | awk '/^Version:/ {print $2}')"
[[ "$luks_version" == "2" ]] || fail "root partition is not LUKS2 (luksDump Version=$luks_version)"

ssh_guest "id -nG $VM_USER" | grep -qw wheel || fail "$VM_USER is not in the wheel group"
root_status="$(ssh_guest 'sudo passwd -S root' | awk '{print $2}')"
[[ "$root_status" == "L" ]] || fail "root account is not locked (passwd -S root: $root_status)"

hostname_actual="$(ssh_guest hostname)"
[[ "$hostname_actual" == vekrona ]] || fail "hostname is '$hostname_actual', expected vekrona"

timezone_actual="$(ssh_guest 'timedatectl show -p Timezone --value')"
[[ "$timezone_actual" == UTC ]] || fail "timezone is '$timezone_actual', expected UTC"

for leaked in /root/anaconda-ks.cfg /root/original-ks.cfg /var/log/anaconda; do
  ssh_guest "sudo test ! -e $leaked" || fail "$leaked exists on the installed system and may contain the LUKS passphrase in plaintext (disable it via the vekrona anaconda.conf drop-in)"
done
log "installed-system checks passed"

boot_id_before="$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')"
reboot_happened() {
  local id
  id="$(ssh_guest 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" || return 1
  [[ -n "$id" && "$id" != "$boot_id_before" ]]
}

REPO_DIR="$(ssh_guest 'find "$HOME" -maxdepth 4 -type f -name install.sh 2>/dev/null | head -n1 | xargs -r dirname')"
[[ -n "$REPO_DIR" ]] || fail "could not find the vekrona repo checkout (install.sh) under the guest user's home"
log "found repo checkout at $REPO_DIR"

FIRSTBOOT_DONE=/var/lib/vekrona/firstboot.done
FIRSTBOOT_FAILED=/var/lib/vekrona/firstboot.failed
firstboot_settled() { ssh_guest "test -e $FIRSTBOOT_DONE -o -e $FIRSTBOOT_FAILED"; }

log "waiting for vekrona-firstboot to finish (timeout ${FIRSTBOOT_TIMEOUT}s)"
poll_until "$FIRSTBOOT_TIMEOUT" "vekrona-firstboot completion marker" firstboot_settled

if ssh_guest "test -e $FIRSTBOOT_FAILED"; then
  echo "---- $FIRSTBOOT_FAILED ----" >&2
  ssh_guest "cat $FIRSTBOOT_FAILED" >&2 || true
  echo "---- journalctl -u vekrona-firstboot ----" >&2
  ssh_guest "journalctl -u vekrona-firstboot --no-pager" >&2 || true
  fail "vekrona-firstboot failed (see output above)"
fi
log "vekrona-firstboot finished successfully"

log "waiting for the post-firstboot reboot"
poll_until "$REBOOT_TIMEOUT" "post-firstboot reboot" reboot_happened
log "guest rebooted; waiting for SSH again (timeout ${SSH_TIMEOUT}s)"
poll_until "$SSH_TIMEOUT" "ssh reachable after reboot" ssh_guest true

log "checking systemctl is-system-running"
state="$(ssh_guest 'systemctl is-system-running --wait' 2>/dev/null || true)"
if [[ "$state" != "running" ]]; then
  failed_units="$(ssh_guest 'systemctl --failed --no-legend' 2>/dev/null || true)"
  echo "failed units:" >&2
  echo "$failed_units" >&2
  fail "system did not reach 'running' after boot: state=$state"
fi

log "checking greetd is active"
ssh_guest 'systemctl is-active --quiet greetd' || fail "greetd is not active"

log "running $REPO_DIR/vm/session-check.sh"
ssh_guest "bash '$REPO_DIR/vm/session-check.sh'" || fail "session-check.sh failed"

log "running $REPO_DIR/vm/login-manager-check.sh"
ssh_guest "bash '$REPO_DIR/vm/login-manager-check.sh'" || fail "login-manager-check.sh failed"

log "running $REPO_DIR/install.sh --skip 10-nvidia 70 (verify)"
verify_output="$(ssh_guest "cd '$REPO_DIR' && ./install.sh --skip 10-nvidia 70" 2>&1)" || {
  echo "$verify_output" >&2
  fail "./install.sh 70 (verify) failed"
}
echo "$verify_output" >&2

log "snapshot/rollback round trip"
snap_n="$(ssh_guest "sudo '$REPO_DIR/bin/vekrona-snapshot' qemu-test | tail -n1")"
[[ "$snap_n" =~ ^[0-9]+$ ]] || fail "vekrona-snapshot did not print a snapshot number: $snap_n"
ssh_guest "sudo '$REPO_DIR/bin/vekrona-rollback' --yes $snap_n" || fail "vekrona-rollback failed"

boot_id_before="$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')"
ssh_guest 'sudo systemctl reboot' || true
log "waiting for the rollback reboot"
poll_until "$REBOOT_TIMEOUT" "rollback reboot" reboot_happened
log "guest rebooted; waiting for SSH again (timeout ${SSH_TIMEOUT}s)"
poll_until "$SSH_TIMEOUT" "ssh reachable after rollback reboot" ssh_guest true

ssh_guest "sudo bash '$REPO_DIR/vm/rollback-check.sh' $snap_n" || fail "rollback-check.sh failed"

state="$(ssh_guest 'systemctl is-system-running --wait' 2>/dev/null || true)"
[[ "$state" == running ]] || fail "system did not reach 'running' after the rollback reboot: state=$state"

log "all checks passed"
