#!/usr/bin/env bash

VM_ISO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-qemu.sh source-path=SCRIPTDIR
source "$VM_ISO_DIR/lib-qemu.sh"

VM_QMP_PY="$VM_ISO_DIR/lib/qmp.py"
VM_RUN_SH="$VM_ISO_DIR/lib/vm-run.sh"
VM_RUNTIME_ROOT="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR must be set}/vekrona-vm"
VM_LOCK_FILE="$XDG_RUNTIME_DIR/vekrona-vm.lock"
VM_LOCK_TIMEOUT_SEC=60
VM_NAME_PATTERN='^[a-z0-9][a-z0-9-]{0,30}$'
VM_MEMORY_HEADROOM_MB=4096
VM_CGROUP_OVERHEAD_MB=1536
VM_LIBVIRT_URI=qemu:///system
SYSTEMCTL_EXIT_UNIT_NOT_LOADED=5
SSH_CONNECT_TIMEOUT_SEC=5
SSH_RETRY_BACKSTOP_SEC=3
WAIT_SERIAL_REPROMPT_STATUS=2

VM_NAME=auth-1
VM_PROFILE=installer
VM_ISO="$VM_ISO_DIR/out/vekrona-release.iso"
VM_RAM_MB=4096
VM_VCPUS=4
VM_FRESH_DISK=0
VM_DISK_GB=40
VM_EXTRA_DISKS_GB=()
VM_DISPLAY=none
VM_OWNER_PID=""
VM_TTL_SEC=7200
VM_IDLE_SEC=1200
VM_COEXIST=()
VM_KERNEL_ARGS=()

vm_log() { printf '[dev-vm] %s\n' "$*" >&2; }
vm_die() { printf '[dev-vm] %s\n' "$*" >&2; exit 1; }

vm_require_commands() {
  local command_name
  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 || vm_die "missing command: $command_name"
  done
}

vm_require_name() {
  [[ "$1" =~ $VM_NAME_PATTERN && "$1" != *-idle ]] \
    || vm_die "invalid VM name '$1': must match $VM_NAME_PATTERN and must not end in -idle"
}

vm_state_dir() { echo "$VM_RUNTIME_ROOT/$1"; }
vm_dev_dir() { echo "$VM_ISO_DIR/dev/$1"; }
vm_service() { echo "vekrona-vm-$1.service"; }
vm_idle_timer() { echo "vekrona-vm-$1-idle.timer"; }

vm_pgrep() {
  local status=0
  pgrep "$@" || status=$?
  (( status <= 1 )) || return "$status"
}

vm_loaded_units() {
  systemctl --user list-units --all --no-legend --plain "$@" | awk '{ print $1 }'
}

vm_our_units() { vm_loaded_units 'vekrona-vm-*'; }

vm_our_services() {
  vm_our_units | awk '/\.service$/ && !/-idle\.service$/'
}

vm_unit_loaded() {
  [[ -n "$(vm_loaded_units "$1")" ]]
}

vm_name_of_service() {
  local unit="${1#vekrona-vm-}"
  echo "${unit%.service}"
}

vm_free_port() {
  python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}

vm_distinct_free_port() {
  local port
  port="$(vm_free_port)"
  while [[ "$port" == "$1" ]]; do port="$(vm_free_port)"; done
  echo "$port"
}

vm_lock() {
  exec {VM_LOCK_FD}>"$VM_LOCK_FILE"
  flock -w "$VM_LOCK_TIMEOUT_SEC" "$VM_LOCK_FD" \
    || vm_die "another dev-vm.sh is starting a VM (lock $VM_LOCK_FILE held for ${VM_LOCK_TIMEOUT_SEC}s)"
}

vm_qemu_process_name() {
  local pid="$1" name
  name="$(tr '\0' '\n' < "/proc/$pid/cmdline" | awk '$0 == "-name" { getline; print; exit }')"
  name="${name#guest=}"
  echo "${name%%,*}"
}

vm_qemu_pids() {
  vm_pgrep '^(qemu-system|vekrona-vm-)'
}

vm_libvirt_running_domains() {
  command -v virsh >/dev/null 2>&1 || return 0
  timeout 10 virsh -c "$VM_LIBVIRT_URI" list --state-running --name | awk 'NF'
}

vm_foreign_vm_names() {
  local pid name
  {
    for pid in $(vm_qemu_pids); do
      name="$(vm_qemu_process_name "$pid")"
      echo "${name:-qemu-pid-$pid}"
    done
    vm_libvirt_running_domains
  } | sort -u
}

vm_available_memory_mb() {
  awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo
}

vm_guard() {
  local ram_mb="$1"
  shift
  local -A acknowledged=()
  local name services unacknowledged=() available_mb need_mb
  for name in "$@"; do acknowledged[$name]=1; done

  services="$(vm_our_services)"
  [[ -z "$services" ]] || vm_die "one of our VMs is already running ($(paste -sd' ' <<< "$services")); stop it with: dev-vm.sh down --name <name>"

  while IFS= read -r name; do
    [[ -z "$name" || -n "${acknowledged[$name]:-}" ]] || unacknowledged+=("$name")
  done <<< "$(vm_foreign_vm_names)"
  (( ${#unacknowledged[@]} == 0 )) \
    || vm_die "foreign VM(s) running: ${unacknowledged[*]}; if their owner agrees to coexist pass --coexist <name> for each"

  available_mb="$(vm_available_memory_mb)"
  need_mb=$(( ram_mb + VM_MEMORY_HEADROOM_MB ))
  (( available_mb >= need_mb )) \
    || vm_die "only ${available_mb} MB memory available, need ${need_mb} MB (VM ${ram_mb} MB + ${VM_MEMORY_HEADROOM_MB} MB headroom)"
}

vm_orphan_state_names() {
  local dir name
  [[ -d "$VM_RUNTIME_ROOT" ]] || return 0
  for dir in "$VM_RUNTIME_ROOT"/*/; do
    [[ -d "$dir" ]] || continue
    name="$(basename "$dir")"
    vm_unit_loaded "$(vm_service "$name")" || echo "$name"
  done
}

vm_state_names() {
  local dir
  [[ -d "$VM_RUNTIME_ROOT" ]] || return 0
  for dir in "$VM_RUNTIME_ROOT"/*/; do
    [[ -d "$dir" ]] && basename "$dir"
  done
}

vm_indented() {
  local line
  while IFS= read -r line; do echo "  $line"; done <<< "$1"
}

vm_print_ours() {
  local units orphans
  units="$(systemctl --user list-units --all --no-legend --plain 'vekrona-vm-*')"
  orphans="$(vm_orphan_state_names)"
  [[ -z "$units" ]] || { echo "our units:"; vm_indented "$units"; }
  [[ -z "$orphans" ]] || { echo "orphan state dirs under $VM_RUNTIME_ROOT:"; vm_indented "$orphans"; }
}

vm_print_foreign() {
  local pid domains
  echo "qemu processes:"
  for pid in $(vm_qemu_pids); do
    printf '  pid=%s name=%s m=%s cgroup=%s\n' "$pid" "$(vm_qemu_process_name "$pid")" \
      "$(tr '\0' '\n' < "/proc/$pid/cmdline" | awk '$0 == "-m" { getline; print; exit }')" \
      "$(awk -F: '$1 == "0" { print $3 }' "/proc/$pid/cgroup")"
  done
  domains="$(vm_libvirt_running_domains)"
  echo "running libvirt domains:"
  [[ -z "$domains" ]] || vm_indented "$domains"
}

vm_has_ours() {
  [[ -n "$(vm_our_units)" || -n "$(vm_state_names)" ]]
}

vm_stop_unit() {
  local unit="$1" output status=0
  output="$(systemctl --user stop "$unit" 2>&1)" || status=$?
  (( status == 0 || status == SYSTEMCTL_EXIT_UNIT_NOT_LOADED )) || vm_die "cannot stop $unit: $output"
}

vm_down() {
  local name="$1"
  vm_stop_unit "$(vm_idle_timer "$name")"
  vm_stop_unit "$(vm_service "$name")"
  rm -rf "$(vm_state_dir "$name")"
}

vm_kill_ours() {
  local unit name
  for unit in $(vm_our_services); do
    name="$(vm_name_of_service "$unit")"
    vm_log "stopping $unit"
    vm_down "$name"
  done
  for unit in $(vm_our_units); do
    vm_log "stopping $unit"
    vm_stop_unit "$unit"
  done
  for name in $(vm_state_names); do
    vm_log "removing state dir of $name"
    vm_down "$name"
  done
}

vm_load_meta() {
  local meta
  meta="$(vm_state_dir "$1")/meta.env"
  [[ -r "$meta" ]] || vm_die "no VM named '$1' (no $meta); start one with: dev-vm.sh up --name $1"
  # shellcheck source=/dev/null
  source "$meta"
}

vm_require_running() {
  vm_require_name "$1"
  vm_load_meta "$1"
  vm_unit_loaded "$(vm_service "$1")" || vm_die "VM '$1' is not running (stale state in $(vm_state_dir "$1")); run: dev-vm.sh down --name $1"
}

vm_arm_idle() {
  local name="$1" seconds="$2" timer service
  timer="$(vm_idle_timer "$name")"
  service="$(vm_service "$name")"
  vm_stop_unit "$timer"
  systemd-run --user --quiet --collect \
    --unit="vekrona-vm-$name-idle" \
    --on-active="${seconds}s" \
    --timer-property="BindsTo=$service" \
    --timer-property="After=$service" \
    -- systemctl --user stop "$service"
}

vm_touch() {
  local name="$1" extra_sec="${2:-0}"
  vm_require_running "$name"
  vm_arm_idle "$name" $(( META_IDLE_SEC + extra_sec ))
}

vm_qmp() {
  local name="$1"
  shift
  python3 -B "$VM_QMP_PY" --sock "$(vm_state_dir "$name")/qmp.sock" "$@"
}

vm_qemu_pid() {
  local pidfile
  pidfile="$(vm_state_dir "$1")/qemu.pid"
  [[ -r "$pidfile" ]] || vm_die "VM '$1' has no qemu pid file; is it running?"
  cat "$pidfile"
}

vm_purge() {
  vm_down "$1"
  rm -rf "$(vm_dev_dir "$1")"
}

vm_serial_log() { echo "$(vm_state_dir "$VM_NAME")/serial.log"; }

vm_serial_offset() { stat -c %s "$(vm_serial_log)"; }

vm_serial_send() {
  python3 -B "$VM_QMP_PY" --sock "$(vm_state_dir "$VM_NAME")/serial.sock" serial-send --enter "$1"
}

vm_wait_serial() {
  local regex="$1" timeout_sec="$2" offset="${3:-0}"
  python3 -B "$VM_QMP_PY" wait-serial --log "$(vm_serial_log)" --pid "$(vm_qemu_pid "$VM_NAME")" \
    --offset "$offset" --timeout "$timeout_sec" "$regex" \
    || vm_die "serial wait failed (see the message above)"
}

vm_serial_matches() {
  local regex="$1" offset="$2"
  grep -qaE -- "$regex" < <(tail -c "+$(( offset + 1 ))" "$(vm_serial_log)")
}

VM_SSH_OPTIONS=(
  -F /dev/null
  -o IdentitiesOnly=yes
  -o IdentityAgent=none
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)

vm_ssh_user() {
  if [[ "$META_PROFILE" == installer ]]; then echo root; else echo vekrona; fi
}

vm_ssh_command() {
  local key="${VEKRONA_TEST_SSH_KEY:-$VM_ISO_DIR/.ssh/id_ed25519}"
  VM_SSH_COMMAND=(ssh "${VM_SSH_OPTIONS[@]}" -p "$META_SSH_PORT" "$(vm_ssh_user)@127.0.0.1")
  if [[ -r "$key" ]]; then
    VM_SSH_COMMAND+=(-i "$key")
  fi
}

vm_wait_ssh() {
  local timeout_sec="$1" reprompt_regex="${2:-}" reprompt_offset="${3:-0}" last_error status
  local serial_log
  serial_log="$(vm_serial_log)"
  vm_ssh_command
  local deadline=$(( SECONDS + timeout_sec ))
  until last_error="$("${VM_SSH_COMMAND[@]}" -o BatchMode=yes -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SEC" true 2>&1)"; do
    if [[ -n "$reprompt_regex" ]] && vm_serial_matches "$reprompt_regex" "$reprompt_offset"; then
      return "$WAIT_SERIAL_REPROMPT_STATUS"
    fi
    (( SECONDS < deadline )) || vm_die "ssh to '$VM_NAME' not ready within ${timeout_sec}s; last error: $last_error"
    status=0
    inotifywait -qq -e modify -t "$SSH_RETRY_BACKSTOP_SEC" "$serial_log" || status=$?
    (( status == 0 || status == 2 )) || vm_die "inotifywait failed on $serial_log (exit $status)"
  done
}

vm_wait_exit() {
  local pidfile
  pidfile="$(vm_state_dir "$VM_NAME")/qemu.pid"
  [[ ! -r "$pidfile" ]] || python3 -B "$VM_QMP_PY" wait-pid "$(<"$pidfile")" --timeout "$1" \
    || vm_die "VM '$VM_NAME' did not exit within ${1}s"
  vm_stop_unit "$(vm_service "$VM_NAME")"
}

vm_exit_status() {
  local exited
  exited="$(vm_state_dir "$VM_NAME")/exited"
  [[ -r "$exited" ]] || vm_die "VM '$VM_NAME' left no exit status ($exited)"
  cat "$exited"
}

vm_extract_from_iso() {
  local iso_path="$1" dest="$2" partial
  if [[ ! -s "$dest" || "$VM_ISO" -nt "$dest" ]]; then
    vm_log "extracting $iso_path from the ISO"
    partial="$dest.partial"
    isoinfo -R -x "$iso_path" -i "$VM_ISO" > "$partial" || vm_die "could not extract $iso_path from $VM_ISO"
    [[ -s "$partial" ]] || vm_die "$iso_path is empty in $VM_ISO"
    mv "$partial" "$dest"
  fi
}

vm_installer_kernel_args() {
  local grub_cfg args arg kept=()
  grub_cfg="$(isoinfo -R -x /EFI/BOOT/grub.cfg -i "$VM_ISO")" || vm_die "could not read /EFI/BOOT/grub.cfg from $VM_ISO"
  args="$(awk '$1 == "linux" { $1 = ""; $2 = ""; print; exit }' <<< "$grub_cfg")"
  [[ -n "$args" ]] || vm_die "no linux line found in the ISO's grub.cfg"
  for arg in $args; do
    case "$arg" in
      inst.updates=*|quiet|rd.live.check) ;;
      *) kept+=("$arg") ;;
    esac
  done
  echo "${kept[*]}"
}

vm_prepare_installer() {
  local dev_dir="$1" serve_dir="$2"
  mkdir -p "$serve_dir"
  vm_extract_from_iso /images/pxeboot/vmlinuz "$dev_dir/vmlinuz"
  vm_extract_from_iso /images/pxeboot/initrd.img "$dev_dir/initrd.img"
  VEKRONA_UPDATES_STAMP_EXTRA="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    bash "$VM_ISO_DIR/anaconda/pack-updates.sh" "$serve_dir/updates.img"
}

vm_usb_device_id() {
  echo "hostusb-${1//:/-}"
}

vm_usb_sysfs_dir() { printf '%s/sys/bus/usb/devices' "${VEKRONA_SYSFS_ROOT:-}"; }

vm_usb_find_device() {
  local vid="${1%%:*}" pid="${1##*:}" dev
  for dev in "$(vm_usb_sysfs_dir)"/*; do
    [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
    [[ "$(<"$dev/idVendor")" == "${vid,,}" && "$(<"$dev/idProduct")" == "${pid,,}" ]] || continue
    echo "$dev"
    return 0
  done
  return 1
}

vm_usb_interface_drivers() {
  local interface driver_link
  for interface in "$1":*; do
    [[ -e "$interface" ]] || continue
    driver_link="$(readlink "$interface/driver" 2>/dev/null)" || driver_link=unbound
    printf '%s=%s\n' "$(basename "$interface")" "$(basename "$driver_link")"
  done
}

vm_usb_require_unclaimed() {
  local spec="$1" dev="$2" drivers
  drivers="$(vm_usb_interface_drivers "$dev")"
  grep -qx '.*=usbfs' <<<"$drivers" || return 0
  vm_die "USB device $spec ($dev) has an interface claimed by another host process through usbfs; QEMU cannot take it over and the guest would fail with \"can't set config #1, error -32\". Interface drivers: $(paste -sd' ' <<<"$drivers"). Usually the smartcard daemon holds a security key's CCID interface: run 'sudo systemctl stop pcscd.socket pcscd.service' and retry"
}

vm_validate_usb_devices() {
  local spec dev node
  for spec in ${VEKRONA_DEV_USB:-}; do
    [[ "$spec" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || vm_die "VEKRONA_DEV_USB entry is not VID:PID in hex: $spec"
    dev="$(vm_usb_find_device "$spec")" || vm_die "USB device $spec is not plugged in"
    node="/dev/bus/usb/$(printf '%03d' "$(<"$dev/busnum")")/$(printf '%03d' "$(<"$dev/devnum")")"
    [[ -r "$node" && -w "$node" ]] \
      || vm_die "no read/write access to $node ($spec); run: sudo setfacl -m u:$USER:rw $node"
    vm_usb_require_unclaimed "$spec" "$dev"
  done
}

vm_usb_host_device_args() {
  local spec
  for spec in ${VEKRONA_DEV_USB:-}; do
    echo "-device"
    echo "usb-host,vendorid=0x${spec%%:*},productid=0x${spec##*:},id=$(vm_usb_device_id "$spec")"
  done
}

vm_create_disk() {
  local path="$1" size_gb="$2"
  if (( VM_FRESH_DISK )) || [[ ! -e "$path" ]]; then
    rm -f "$path"
    qemu-img create -f qcow2 "$path" "${size_gb}G" >/dev/null
  fi
}

vm_disk_paths() {
  local dev_dir="$1" index
  echo "$dev_dir/disk.qcow2"
  for index in "${!VM_EXTRA_DISKS_GB[@]}"; do
    echo "$dev_dir/extra-$index.qcow2"
  done
}

vm_create_disks() {
  local dev_dir="$1" index
  vm_create_disk "$dev_dir/disk.qcow2" "$VM_DISK_GB"
  for index in "${!VM_EXTRA_DISKS_GB[@]}"; do
    vm_create_disk "$dev_dir/extra-$index.qcow2" "${VM_EXTRA_DISKS_GB[$index]}"
  done
}

vm_build_qemu_command() {
  local state_dir="$1" dev_dir="$2" ssh_port="$3" http_port="$4" ovmf_code="$5" ovmf_vars="$6"
  local disk usb_arg
  VM_QEMU_CMD=(
    qemu-system-x86_64
    -name "vekrona-vm-$VM_NAME,process=vekrona-vm-$VM_NAME"
    -enable-kvm
    -machine q35
    -cpu host
    -m "$VM_RAM_MB"
    -smp "$VM_VCPUS"
    -no-user-config
    -nodefaults
    -display "$VM_DISPLAY"
    -pidfile "$state_dir/qemu.pid"
    -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
    -drive "if=pflash,format=raw,file=$ovmf_vars"
  )
  if [[ "$VM_PROFILE" != disk ]]; then
    VM_QEMU_CMD+=(-drive "file=$VM_ISO,media=cdrom,if=ide,readonly=on")
  fi
  while IFS= read -r disk; do
    VM_QEMU_CMD+=(-drive "file=$disk,format=qcow2,if=virtio,cache=writeback")
  done < <(vm_disk_paths "$dev_dir")
  VM_QEMU_CMD+=(
    -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
    -device "virtio-net-pci,netdev=net0"
    -device virtio-vga
    -device qemu-xhci
    -device usb-tablet
    -device usb-kbd
    -qmp "unix:$state_dir/qmp.sock,server=on,wait=off"
    -chardev "socket,id=serial0,path=$state_dir/serial.sock,server=on,wait=off,logfile=$state_dir/serial.log"
    -serial chardev:serial0
  )
  while IFS= read -r usb_arg; do
    [[ -z "$usb_arg" ]] || VM_QEMU_CMD+=("$usb_arg")
  done < <(vm_usb_host_device_args)
  if [[ "$VM_PROFILE" == iso ]]; then
    VM_QEMU_CMD+=(-no-reboot)
  fi
  if [[ "$VM_PROFILE" == installer ]]; then
    VM_QEMU_CMD+=(
      -kernel "$dev_dir/vmlinuz"
      -initrd "$dev_dir/initrd.img"
      -append "$(vm_installer_kernel_args) console=ttyS0 console=tty0 inst.updates=http://10.0.2.2:${http_port}/updates.img inst.sshd inst.graphical ${VM_KERNEL_ARGS[*]}"
      -no-reboot
    )
  fi
}

vm_env_line() {
  printf '%s=%q\n' "$1" "$2"
}

vm_write_meta() {
  local state_dir="$1" ssh_port="$2" http_port="$3"
  {
    vm_env_line META_NAME "$VM_NAME"
    vm_env_line META_OWNER_PID "$VM_OWNER_PID"
    vm_env_line META_ARGV "$VM_ARGV"
    vm_env_line META_CWD "$PWD"
    vm_env_line META_PROFILE "$VM_PROFILE"
    vm_env_line META_UNIT "$(vm_service "$VM_NAME")"
    vm_env_line META_SSH_PORT "$ssh_port"
    vm_env_line META_HTTP_PORT "$http_port"
    vm_env_line META_START_TIME "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    vm_env_line META_IDLE_SEC "$VM_IDLE_SEC"
    vm_env_line META_TTL_SEC "$VM_TTL_SEC"
  } > "$state_dir/meta.env"
}

vm_write_run_env() {
  local state_dir="$1" http_port="$2" serve_dir="$3"
  {
    vm_env_line STATE_DIR "$state_dir"
    vm_env_line QMP_PY "$VM_QMP_PY"
    vm_env_line OWNER_PID "$VM_OWNER_PID"
    vm_env_line HTTP_PORT "$http_port"
    vm_env_line SERVE_DIR "$serve_dir"
    printf 'QEMU_CMD=(%s)\n' "$(printf '%q ' "${VM_QEMU_CMD[@]}")"
  } > "$state_dir/run.env"
}

vm_display_environment_args() {
  local variable
  [[ "$VM_DISPLAY" == gtk ]] || return 0
  for variable in DISPLAY WAYLAND_DISPLAY XAUTHORITY; do
    [[ -z "${!variable:-}" ]] || echo "--setenv=$variable"
  done
}

vm_start_unit() {
  local state_dir="$1" deadline_sec=60 created arg
  local display_args=()
  while IFS= read -r arg; do display_args+=("$arg"); done < <(vm_display_environment_args)

  coproc WATCH { exec inotifywait -e create --format %f --include '/(qmp\.sock|exited)$' -t "$deadline_sec" "$state_dir" 2>&1; }
  read -r _ <&"${WATCH[0]}"
  read -r _ <&"${WATCH[0]}"

  systemd-run --user --quiet --collect --service-type=exec \
    --unit="vekrona-vm-$VM_NAME" \
    -p "MemoryMax=$(( VM_RAM_MB + VM_CGROUP_OVERHEAD_MB ))M" \
    -p MemorySwapMax=0 \
    -p OOMPolicy=kill \
    -p OOMScoreAdjust=500 \
    -p "RuntimeMaxSec=$VM_TTL_SEC" \
    -p TimeoutStopSec=15 \
    -p KillMode=control-group \
    "${display_args[@]}" \
    -- bash "$VM_RUN_SH" "$state_dir/run.env"

  if ! read -r created <&"${WATCH[0]}"; then
    vm_down "$VM_NAME"
    vm_die "QEMU did not open its QMP socket within ${deadline_sec}s"
  fi
  wait "$WATCH_PID"
  if [[ "$created" != qmp.sock ]]; then
    journalctl --user --no-pager -n 30 -u "vekrona-vm-$VM_NAME" >&2
    vm_down "$VM_NAME"
    vm_die "VM '$VM_NAME' exited before opening its QMP socket; see the journal above"
  fi
  python3 -B "$VM_QMP_PY" --sock "$state_dir/qmp.sock" greeting
}

vm_validate_up_options() {
  vm_require_name "$VM_NAME"
  case "$VM_PROFILE" in installer|iso|disk) ;; *) vm_die "unknown profile '$VM_PROFILE' (installer|iso|disk)" ;; esac
  case "$VM_DISPLAY" in none|gtk) ;; *) vm_die "unknown display '$VM_DISPLAY' (none|gtk)" ;; esac
  [[ "$VM_PROFILE" == disk || -r "$VM_ISO" ]] || vm_die "ISO not readable: $VM_ISO"
  [[ -z "$VM_OWNER_PID" || -d "/proc/$VM_OWNER_PID" ]] || vm_die "owner pid $VM_OWNER_PID is not running"
  [[ -r /dev/kvm && -w /dev/kvm ]] || vm_die "/dev/kvm is missing or not accessible; add this user to the kvm group and re-login"
  vm_require_commands qemu-system-x86_64 qemu-img python3 systemd-run systemctl flock inotifywait journalctl
  [[ "$VM_PROFILE" != installer ]] || vm_require_commands isoinfo
  vm_validate_usb_devices
}

vm_print_command() {
  local dev_dir pair http_port=""
  dev_dir="$(vm_dev_dir "$VM_NAME")"
  pair="$(find_ovmf)" || vm_die "OVMF firmware not found"
  [[ "$VM_PROFILE" != installer ]] || http_port="$(vm_free_port)"
  vm_build_qemu_command "$(vm_state_dir "$VM_NAME")" "$dev_dir" "$(vm_free_port)" "$http_port" "${pair%%:*}" "$dev_dir/OVMF_VARS.fd"
  printf '%q ' "${VM_QEMU_CMD[@]}"
  echo
}

vm_up() {
  local state_dir dev_dir serve_dir ovmf_vars ovmf_code ssh_port http_port=""
  vm_validate_up_options
  state_dir="$(vm_state_dir "$VM_NAME")"
  dev_dir="$(vm_dev_dir "$VM_NAME")"
  serve_dir="$dev_dir/serve"

  vm_lock
  vm_guard "$VM_RAM_MB" "${VM_COEXIST[@]}"
  if [[ -e "$state_dir" ]]; then
    vm_log "removing orphan state dir $state_dir"
    rm -rf "$state_dir"
  fi
  mkdir -p "$state_dir" "$dev_dir"

  [[ "$VM_PROFILE" != installer ]] || vm_prepare_installer "$dev_dir" "$serve_dir"
  vm_create_disks "$dev_dir"
  ovmf_vars="$dev_dir/OVMF_VARS.fd"
  if (( VM_FRESH_DISK )) || [[ ! -e "$ovmf_vars" ]]; then
    ovmf_code="$(init_ovmf "$ovmf_vars")" || vm_die "OVMF setup failed"
  else
    ovmf_code="$(find_ovmf)"
    ovmf_code="${ovmf_code%%:*}"
  fi

  ssh_port="$(vm_free_port)"
  if [[ "$VM_PROFILE" == installer ]]; then
    http_port="$(vm_distinct_free_port "$ssh_port")"
  fi

  vm_build_qemu_command "$state_dir" "$dev_dir" "$ssh_port" "$http_port" "$ovmf_code" "$ovmf_vars"
  vm_write_run_env "$state_dir" "$http_port" "$serve_dir"
  vm_write_meta "$state_dir" "$ssh_port" "$http_port"
  vm_start_unit "$state_dir"
  vm_arm_idle "$VM_NAME" "$VM_IDLE_SEC"
  vm_log "VM '$VM_NAME' is up: ssh port $ssh_port, state $state_dir, stops after ${VM_IDLE_SEC}s idle or ${VM_TTL_SEC}s total"
}
