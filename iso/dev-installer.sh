#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF >&2
usage: $(basename "$0") [--iso PATH] [--name vekrona-auth-N] [--fresh-disk] [--print]

Boots the installer from a release ISO in QEMU with a freshly packed
updates.img served over HTTP, so add-on edits need no ISO rebuild.
Set VEKRONA_DEV_USB="VID:PID ..." to pass USB devices through.
EOF
  exit "${1:-2}"
}

ISO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib-qemu.sh source-path=SCRIPTDIR
source "$ISO_DIR/lib-qemu.sh"

die() { printf '[dev-installer] %s\n' "$*" >&2; exit 1; }
log() { printf '[dev-installer] %s\n' "$*" >&2; }

iso="$ISO_DIR/out/vekrona-release.iso"
name="vekrona-auth-1"
fresh_disk=0
print_only=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --iso) [[ $# -ge 2 ]] || usage; iso="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || usage; name="$2"; shift 2 ;;
    --fresh-disk) fresh_disk=1; shift ;;
    --print) print_only=1; shift ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
done

[[ "$name" =~ ^vekrona-auth-[A-Za-z0-9._-]+$ ]] || die "name must match vekrona-auth-*: $name"
[[ -r "$iso" ]] || die "ISO not readable: $iso"
for c in isoinfo qemu-system-x86_64 qemu-img python3; do
  command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
done
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is missing or not accessible; add this user to the kvm group and re-login"

state_dir="$ISO_DIR/dev/$name"
serve_dir="$state_dir/serve"
mkdir -p "$serve_dir"

free_port() {
  python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
'
}

extract_from_iso() {
  local iso_path="$1" dest="$2"
  if [[ ! -s "$dest" || "$iso" -nt "$dest" ]]; then
    log "extracting $iso_path from the ISO"
    local tmp="$dest.partial"
    isoinfo -R -x "$iso_path" -i "$iso" > "$tmp" || die "could not extract $iso_path from $iso"
    [[ -s "$tmp" ]] || die "$iso_path is empty in $iso"
    mv "$tmp" "$dest"
  fi
}

installer_kernel_args() {
  local grub_cfg args arg kept=()
  grub_cfg="$(isoinfo -R -x /EFI/BOOT/grub.cfg -i "$iso")" || die "could not read /EFI/BOOT/grub.cfg from $iso"
  args="$(awk '$1 == "linux" { $1 = ""; $2 = ""; print; exit }' <<< "$grub_cfg")"
  [[ -n "$args" ]] || die "no linux line found in the ISO's grub.cfg"
  for arg in $args; do
    case "$arg" in
      inst.updates=*|quiet|rd.live.check) ;;
      *) kept+=("$arg") ;;
    esac
  done
  echo "${kept[*]}"
}

usb_args=()
collect_usb_host_device_args() {
  local spec vid pid dev found bus devnum node
  for spec in ${VEKRONA_DEV_USB:-}; do
    [[ "$spec" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || die "VEKRONA_DEV_USB entry is not VID:PID in hex: $spec"
    vid="${spec%%:*}"
    pid="${spec##*:}"
    found=""
    for dev in /sys/bus/usb/devices/*; do
      [[ -r "$dev/idVendor" && -r "$dev/idProduct" ]] || continue
      [[ "$(<"$dev/idVendor")" == "${vid,,}" && "$(<"$dev/idProduct")" == "${pid,,}" ]] || continue
      found="$dev"
      break
    done
    [[ -n "$found" ]] || die "USB device $spec is not plugged in"
    bus="$(printf '%03d' "$(<"$found/busnum")")"
    devnum="$(printf '%03d' "$(<"$found/devnum")")"
    node="/dev/bus/usb/$bus/$devnum"
    [[ -r "$node" && -w "$node" ]] \
      || die "no read/write access to $node ($spec); run: sudo setfacl -m u:$USER:rw $node"
    usb_args+=(-device "usb-host,vendorid=0x${vid},productid=0x${pid}")
  done
}

extract_from_iso /images/pxeboot/vmlinuz "$state_dir/vmlinuz"
extract_from_iso /images/pxeboot/initrd.img "$state_dir/initrd.img"
iso_args="$(installer_kernel_args)"

VEKRONA_UPDATES_STAMP_EXTRA="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  bash "$ISO_DIR/anaconda/pack-updates.sh" "$serve_dir/updates.img"

disk="$state_dir/disk.qcow2"
if (( fresh_disk )) || [[ ! -e "$disk" ]]; then
  rm -f "$disk"
  qemu-img create -f qcow2 "$disk" 40G >/dev/null
fi

ovmf_vars="$state_dir/OVMF_VARS.fd"
ovmf_code="$(init_ovmf "$ovmf_vars")" || die "OVMF setup failed"

http_port="$(free_port)"
ssh_port="$(free_port)"
while [[ "$ssh_port" == "$http_port" ]]; do ssh_port="$(free_port)"; done

collect_usb_host_device_args

qemu_cmd=(
  qemu-system-x86_64
  -name "$name"
  -enable-kvm
  -machine q35
  -cpu host
  -m 6144
  -smp 4
  -no-user-config
  -nodefaults
  -drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
  -drive "if=pflash,format=raw,file=$ovmf_vars"
  -drive "file=$iso,media=cdrom,if=ide,readonly=on"
  -drive "file=$disk,format=qcow2,if=virtio,cache=writeback"
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${ssh_port}-:22"
  -device "virtio-net-pci,netdev=net0"
  -device virtio-vga
  -display gtk
  -device qemu-xhci
  -device usb-tablet
  -kernel "$state_dir/vmlinuz"
  -initrd "$state_dir/initrd.img"
  -append "$iso_args inst.updates=http://10.0.2.2:${http_port}/updates.img inst.sshd"
  "${usb_args[@]}"
)

ssh_hint="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $ssh_port root@127.0.0.1"

if (( print_only )); then
  printf '%q ' "${qemu_cmd[@]}"
  echo
  log "installer ssh (once booted): $ssh_hint"
  exit 0
fi

http_pid=""
cleanup() {
  [[ -z "$http_pid" ]] || kill "$http_pid" 2>/dev/null || true
}
trap cleanup EXIT

python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$serve_dir" >"$state_dir/http.log" 2>&1 &
http_pid=$!

command -v curl >/dev/null 2>&1 || die "missing command: curl"
updates_url="http://127.0.0.1:$http_port/updates.img"
for _ in {1..50}; do
  kill -0 "$http_pid" 2>/dev/null || die "http server exited early; see $state_dir/http.log"
  curl -sf --head --max-time 1 "$updates_url" >/dev/null && break
  sleep 0.1
done
curl -sf --head --max-time 1 "$updates_url" >/dev/null || die "updates.img not reachable at $updates_url"

log "updates.img served on 127.0.0.1:$http_port, installer ssh: $ssh_hint"
"${qemu_cmd[@]}"
