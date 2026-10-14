#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
CONF="$ROOT/etc/dracut.conf.d/99-nvidia-dracut.conf"

# What dracut ends up asking for: it sets $kernel (and, for --sysroot, $dracutsysrootdir) before it sources the file.
add_drivers_for() { # add_drivers_for <kernel version>
  bash -c 'add_drivers=" crc32c "; dracutsysrootdir=$1; kernel=$2; source "$3"; printf "%s" "$add_drivers"' _ "$work" "$1" "$CONF"
}

mkdir -p "$work/usr/lib/modules/7.0/extra/nvidia" "$work/usr/lib/modules/7.1/extra/nvidia" "$work/usr/lib/modules/7.2/extra/nvidia"
touch "$work/usr/lib/modules/7.0/extra/nvidia/nvidia.ko.xz" "$work/usr/lib/modules/7.1/extra/nvidia/nvidia.ko.zst"

[[ "$(add_drivers_for 7.0)" == " crc32c  nvidia nvidia_modeset nvidia_uvm nvidia_drm " ]] || die "a kernel with the module did not get the nvidia drivers: '$(add_drivers_for 7.0)'"
[[ "$(add_drivers_for 7.1)" == *" nvidia nvidia_modeset "* ]] || die "a .zst module did not get the nvidia drivers"
log "ok: a kernel with the nvidia module gets the nvidia drivers, added to the others, whatever the compression"

touch "$work/usr/lib/modules/7.2/extra/nvidia/nvidia-drm.ko"
for kver in 7.2 7.3 ""; do
  [[ "$(add_drivers_for "$kver")" == " crc32c " ]] || die "kernel '$kver' without the module asked for nvidia drivers: '$(add_drivers_for "$kver")'"
done
log "ok: a kernel without the module (not built yet, not installed, none given) asks for no nvidia drivers, which dracut would log as FAILED"
