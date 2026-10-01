#!/usr/bin/env bash
set -euo pipefail

ISO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib-vm.sh source-path=SCRIPTDIR
source "$ISO_DIR/lib-vm.sh"

usage() {
  cat <<EOF >&2
usage: $(basename "$0") [--print] <test.iso>

Installs the test ISO unattended under QEMU/KVM, boots the installed disk
(typing the LUKS passphrase on the serial console), then asserts over SSH.
Both phases run through iso/lib-vm.sh: one transient systemd user unit each,
with a memory cap, a hard runtime limit and binding to this script's pid.
--print shows the QEMU command line of both phases and starts nothing.
Set VEKRONA_VM_COEXIST="NAME ..." to acknowledge foreign VMs that may keep running.
Set VEKRONA_QEMU_KEEP_DISK_ON_FAILURE=1 to keep the VM's disk (iso/dev/qemu-test) when a
check fails; boot it by hand with: iso/dev-vm.sh up --name qemu-test --profile disk
EOF
  exit "${1:-2}"
}

print_only=0
TEST_ISO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --print) print_only=1; shift ;;
    -h|--help) usage 0 ;;
    -*) usage ;;
    *) [[ -z "$TEST_ISO" ]] || usage; TEST_ISO="$1"; shift ;;
  esac
done
[[ -n "$TEST_ISO" ]] || usage

log()  { printf '[qemu-test] %s\n' "$*" >&2; }
fail() { printf '[qemu-test] FAILED: %s\n' "$*" >&2; exit 1; }

[[ -r "$TEST_ISO" ]] || fail "test ISO not readable: $TEST_ISO"
vm_require_commands ssh

VM_NAME=qemu-test
VM_ISO="$(readlink -f "$TEST_ISO")"
VM_RAM_MB="${VEKRONA_QEMU_RAM_MB:-4096}"
VM_VCPUS="${VEKRONA_QEMU_VCPUS:-4}"
VM_DISK_GB="${VEKRONA_QEMU_DISK_GB:-40}"
VM_DISPLAY="${VEKRONA_QEMU_DISPLAY:-none}"
VM_OWNER_PID="$$"
VM_ARGV="$(basename "$0") $*"
read -ra VM_COEXIST <<<"${VEKRONA_VM_COEXIST:-}"

INSTALL_TIMEOUT="${VEKRONA_INSTALL_TIMEOUT:-3600}"
SSH_TIMEOUT="${VEKRONA_SSH_TIMEOUT:-300}"
FIRSTBOOT_TIMEOUT="${VEKRONA_FIRSTBOOT_TIMEOUT:-2400}"
REBOOT_TIMEOUT="${VEKRONA_REBOOT_TIMEOUT:-180}"
ASSERTIONS_MARGIN_SEC=1800
INSTALL_TTL_SEC=$(( INSTALL_TIMEOUT + ASSERTIONS_MARGIN_SEC ))
INSTALLED_TTL_SEC=$(( 3 * REBOOT_TIMEOUT + 3 * SSH_TIMEOUT + FIRSTBOOT_TIMEOUT + ASSERTIONS_MARGIN_SEC ))
SSH_KEY="${VEKRONA_TEST_SSH_KEY:-$ISO_DIR/.ssh/id_ed25519}"
export VEKRONA_TEST_SSH_KEY="$SSH_KEY"

LUKS_PASSPHRASE="vekrona"
LUKS_PROMPT_REGEX="Please enter passphrase"
LUKS_REJECTED_REGEX="Passphrase incorrect|Failed to activate"
FIRSTBOOT_STATE_DIR=/var/lib/vekrona
FIRSTBOOT_DONE=$FIRSTBOOT_STATE_DIR/firstboot.done
FIRSTBOOT_FAILED=$FIRSTBOOT_STATE_DIR/firstboot.failed
FIRSTBOOT_WATCH_RECHECK_SEC=300
SSH_CONNECTION_LOST_STATUS=255
VM_USER="vekrona"

phase_options() {
  VM_PROFILE="$1"
  VM_FRESH_DISK="$2"
  VM_TTL_SEC="$3"
  VM_IDLE_SEC="$3"
}

if (( print_only )); then
  phase_options iso 1 "$INSTALL_TTL_SEC"
  vm_validate_up_options
  log "phase 1 (unattended install from the test ISO):"
  vm_print_command
  phase_options disk 0 "$INSTALLED_TTL_SEC"
  vm_validate_up_options
  log "phase 2 (boot of the installed disk, same disk image and UEFI variables):"
  vm_print_command
  exit 0
fi

[[ -r "$SSH_KEY" ]] || fail "test SSH private key not readable: $SSH_KEY (set VEKRONA_TEST_SSH_KEY to the private half of the key passed to iso/build.sh --test-ssh-pubkey)"

LOG_DIR="${VEKRONA_QEMU_LOG_DIR:-$(mktemp -d -t vekrona-qemu-test-logs.XXXXXX)}"
mkdir -p "$LOG_DIR"
log "serial console logs: $LOG_DIR"

save_serial_log() {
  local phase="$1" serial_log
  serial_log="$(vm_serial_log)"
  [[ ! -e "$serial_log" ]] || cp "$serial_log" "$LOG_DIR/serial-$phase.log"
}

cleanup() {
  local rc=$?
  local serial_log
  if [[ $rc -ne 0 ]]; then
    save_serial_log "$current_phase"
    for serial_log in "$LOG_DIR"/serial-*.log; do
      [[ -e "$serial_log" ]] || continue
      echo "---- serial console log: $serial_log (tail) ----" >&2
      tail -n 200 "$serial_log" >&2
      echo "---- end $serial_log ----" >&2
    done
  fi
  if [[ $rc -ne 0 && "${VEKRONA_QEMU_KEEP_DISK_ON_FAILURE:-0}" == 1 ]]; then
    vm_down "$VM_NAME"
    log "kept the disk in $(vm_dev_dir "$VM_NAME"); boot it with: iso/dev-vm.sh up --name $VM_NAME --profile disk"
  else
    vm_purge "$VM_NAME"
  fi
}

start_phase() {
  vm_up
  current_phase="$1"
  trap cleanup EXIT
  vm_load_meta "$VM_NAME"
  vm_ssh_command
}

ssh_guest() { "${VM_SSH_COMMAND[@]}" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SEC" "$@"; }

unlock_and_wait_for_ssh() {
  local wait_from="$1" prompt_seen_at status=0
  vm_wait_serial "$LUKS_PROMPT_REGEX" "$REBOOT_TIMEOUT" "$wait_from"
  prompt_seen_at="$(vm_serial_offset)"
  vm_serial_send "$LUKS_PASSPHRASE"
  vm_wait_ssh "$SSH_TIMEOUT" "$LUKS_REJECTED_REGEX" "$prompt_seen_at" || status=$?
  (( status != WAIT_SSH_ABORTED_STATUS )) || fail "the installed disk rejected the LUKS passphrase"
  (( status == 0 )) || fail "waiting for ssh failed with status $status"
}

log "phase 1: booting the test ISO to install (install timeout ${INSTALL_TIMEOUT}s)"
phase_options iso 1 "$INSTALL_TTL_SEC"
start_phase install
vm_wait_exit "$INSTALL_TIMEOUT"
install_status="$(vm_exit_status)"
save_serial_log install
vm_down "$VM_NAME"
[[ "$install_status" == 0 ]] || fail "qemu exited with status $install_status during install (expected 0: -no-reboot makes qemu exit cleanly instead of rebooting when Anaconda finishes)"
log "phase 1 done: installer finished and qemu exited"

log "phase 2: booting the installed disk (cdrom detached, LUKS-encrypted root)"
phase_options disk 0 "$INSTALLED_TTL_SEC"
start_phase run
unlock_and_wait_for_ssh 0

log "checking the installed system: LUKS2 root, wheel membership, locked root, hostname, timezone, no leaked passphrase"
root_source="$(ssh_guest "findmnt -no SOURCE /" | sed 's/\[.*//')"
[[ -n "$root_source" ]] || fail "could not resolve the root filesystem's source device"
root_type="$(ssh_guest "lsblk -no TYPE '$root_source'")"
[[ "$root_type" == "crypt" ]] || fail "root filesystem is not on a LUKS mapper device (lsblk TYPE=$root_type)"
luks_device="$(ssh_guest "sudo cryptsetup status '$root_source'" | awk '$1 == "device:" {print $2}')"
[[ -n "$luks_device" ]] || fail "could not resolve the LUKS mapper device's backing partition"
luks_version="$(ssh_guest "sudo cryptsetup luksDump '$luks_device'" | awk '/^Version:/ {print $2}')"
[[ "$luks_version" == "2" ]] || fail "root partition is not LUKS2 (luksDump Version=$luks_version)"

user_groups="$(ssh_guest "id -nG $VM_USER")"
grep -qw wheel <<<"$user_groups" || fail "$VM_USER is not in the wheel group"
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
assert_rebooted() {
  local boot_id_after
  boot_id_after="$(ssh_guest 'cat /proc/sys/kernel/random/boot_id')"
  [[ -n "$boot_id_after" && "$boot_id_after" != "$boot_id_before" ]] || fail "guest answered over ssh but its boot_id did not change: it did not reboot"
}

REPO_DIR="$(ssh_guest "find \"\$HOME\" -maxdepth 4 -type f -name install.sh 2>/dev/null | head -n1 | xargs -r dirname")"
[[ -n "$REPO_DIR" ]] || fail "could not find the vekrona repo checkout (install.sh) under the guest user's home"
log "found repo checkout at $REPO_DIR"

log "waiting for vekrona-firstboot to finish (timeout ${FIRSTBOOT_TIMEOUT}s)"
firstboot_settled_status=0
ssh_guest "command -v inotifywait >/dev/null && timeout $FIRSTBOOT_TIMEOUT bash -c 'until test -e $FIRSTBOOT_DONE -o -e $FIRSTBOOT_FAILED; do inotifywait -qq -t $FIRSTBOOT_WATCH_RECHECK_SEC -e create,moved_to $FIRSTBOOT_STATE_DIR; s=\$?; [ \$s -eq 0 -o \$s -eq 2 ] || exit \$s; done'" \
  || firstboot_settled_status=$?
case "$firstboot_settled_status" in
  0) ;;
  "$SSH_CONNECTION_LOST_STATUS") log "ssh connection dropped while waiting: the guest is probably rebooting after firstboot" ;;
  124) fail "vekrona-firstboot did not settle within ${FIRSTBOOT_TIMEOUT}s" ;;
  *) fail "waiting for the vekrona-firstboot marker failed with status $firstboot_settled_status" ;;
esac
firstboot_reboot_from="$(vm_serial_offset)"

if (( firstboot_settled_status == 0 )) && ssh_guest "test -e $FIRSTBOOT_FAILED"; then
  echo "---- $FIRSTBOOT_FAILED ----" >&2
  ssh_guest "cat $FIRSTBOOT_FAILED" >&2 || true
  echo "---- journalctl -u vekrona-firstboot ----" >&2
  ssh_guest "journalctl -u vekrona-firstboot --no-pager" >&2 || true
  fail "vekrona-firstboot failed (see output above)"
fi

log "waiting for the post-firstboot reboot, the LUKS prompt and SSH again"
unlock_and_wait_for_ssh "$firstboot_reboot_from"
assert_rebooted
ssh_guest "test -e $FIRSTBOOT_DONE" || fail "firstboot did not leave $FIRSTBOOT_DONE"
ssh_guest "test ! -e $FIRSTBOOT_FAILED" || fail "firstboot left $FIRSTBOOT_FAILED"
log "vekrona-firstboot finished successfully"

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
rollback_reboot_from="$(vm_serial_offset)"
ssh_guest 'sudo systemctl reboot' || true
log "waiting for the rollback reboot, the LUKS prompt and SSH again"
unlock_and_wait_for_ssh "$rollback_reboot_from"
assert_rebooted

ssh_guest "sudo bash '$REPO_DIR/vm/rollback-check.sh' $snap_n" || fail "rollback-check.sh failed"

state="$(ssh_guest 'systemctl is-system-running --wait' 2>/dev/null || true)"
[[ "$state" == running ]] || fail "system did not reach 'running' after the rollback reboot: state=$state"

save_serial_log run
log "all checks passed"
