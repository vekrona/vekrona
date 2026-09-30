#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd rpm dnf5 grubby modinfo

target_kver="$(uname -r)"
assert_running_kernel_is_latest() {
  local latest
  latest="$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)"
  [[ "$latest" == "$target_kver" ]] || die "reboot into the latest installed kernel first (running $target_kver, latest installed $latest)"
}

assert_running_kernel_is_latest
ensure_pkg "kernel-devel-$target_kver"

CUDA_REPO_ID="cuda-fedora44-x86_64"
CUDA_REPOFILE_URL="https://developer.download.nvidia.com/compute/cuda/repos/fedora44/x86_64/cuda-fedora44.repo"
CUDA_EXCLUDE='nvidia-driver*,cuda-drivers*,nvidia-modprobe,nvidia-persistenced,nvidia-settings,nvidia-libXNVCtrl*,nvidia-xconfig,nvidia-open,nvidia-imex,nvidia-kmod-common,libnvidia-fbc,kmod-nvidia-*-dkms,nvidia-fs*,nvidia-gds*,xorg-x11-nvidia*'
OLD_CUDA_REPOFILE="/etc/yum.repos.d/cuda-fedora43.repo"

if repo_enabled "$CUDA_REPO_ID"; then
  log "repo enabled: $CUDA_REPO_ID"
else
  log "adding repo: $CUDA_REPO_ID"
  root dnf5 config-manager addrepo --from-repofile="$CUDA_REPOFILE_URL"
  repo_enabled "$CUDA_REPO_ID" || die "repo not enabled: $CUDA_REPO_ID"
fi

root dnf5 config-manager setopt "$CUDA_REPO_ID.excludepkgs=$CUDA_EXCLUDE"
grep -rqE '^excludepkgs[[:space:]]*=.*nvidia-driver' /etc/dnf/repos.override.d /etc/yum.repos.d 2>/dev/null \
  || die "excludepkgs for $CUDA_REPO_ID not persisted under /etc/dnf/repos.override.d or /etc/yum.repos.d"
log "ok: $CUDA_REPO_ID excludes cuda-repo driver packages"

if [[ -f "$OLD_CUDA_REPOFILE" ]]; then
  log "removing: $OLD_CUDA_REPOFILE"
  root rm -f "$OLD_CUDA_REPOFILE"
  [[ -f "$OLD_CUDA_REPOFILE" ]] && die "failed to remove $OLD_CUDA_REPOFILE"
fi

cuda_driver_installed() {
  if pkg_installed cuda-drivers; then return 0; fi
  if [[ -n "$(rpm -qa 'nvidia-driver*')" ]]; then return 0; fi
  return 1
}

REMOVE_GLOBS=(cuda-drivers 'nvidia-driver*' kmod-nvidia-latest-dkms nvidia-kmod-common 'libnvidia-*' nvidia-libXNVCtrl nvidia-modprobe nvidia-persistenced nvidia-settings)
INSTALL_PKGS=(akmod-nvidia xorg-x11-drv-nvidia-cuda)

if cuda_driver_installed; then
  mapfile -t remove_pkgs < <(
    for pat in "${REMOVE_GLOBS[@]}"; do rpm -qa --qf '%{NAME}\n' "$pat" 2>/dev/null; done | sort -u
  )
  if [[ ${#remove_pkgs[@]} -gt 0 ]]; then
    log "removing cuda-repo driver and installing akmod-nvidia in one transaction"
    root dnf5 "do" -y --action=remove "${remove_pkgs[@]}" --action=install "${INSTALL_PKGS[@]}"
  else
    log "no cuda-repo driver packages matched, installing akmod-nvidia"
    ensure_pkg "${INSTALL_PKGS[@]}"
  fi
else
  log "no cuda-repo driver installed, skipping removal"
  ensure_pkg "${INSTALL_PKGS[@]}"
fi

require_cmd akmods

assert_running_kernel_is_latest
ensure_pkg "kernel-devel-$target_kver"

if pkg_installed cuda-toolkit; then
  root dnf upgrade -y cuda-toolkit
fi

log "rebuilding akmods for $target_kver"
root akmods --force --kernels "$target_kver"

nvidia_version="$(modinfo -F version nvidia)"
[[ "${nvidia_version%%.*}" -ge 615 ]] || die "unexpected nvidia module version: $nvidia_version (expected >= 615)"
log "ok: nvidia module version $nvidia_version"

modinfo -k "$target_kver" nvidia >/dev/null 2>&1 || die "nvidia module missing for kernel $target_kver"
log "ok: nvidia module present for kernel $target_kver"

ensure_kernel_arg nvidia.NVreg_EnableGpuFirmware=0 pcie_aspm=off

if grubby_has_arg "rd.driver.blacklist=nouveau"; then
  log "ok: nouveau blacklisted via grubby"
else
  ensure_kernel_arg "rd.driver.blacklist=nouveau,nova_core" "modprobe.blacklist=nouveau,nova_core"
fi

modprobe_option_active() {
  grep -rhE '^[[:space:]]*[^#[:space:]]' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null | grep -qE -- "$1"
}

if modprobe_option_active 'NVreg_PreserveVideoMemoryAllocations=1' \
  && modprobe_option_active 'NVreg_TemporaryFilePath=/var/tmp'; then
  log "ok: nvidia modprobe options present"
else
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-nvidia.conf" /etc/modprobe.d/vekrona-nvidia.conf
fi

ensure_system_unit enabled nvidia-suspend nvidia-resume nvidia-hibernate

lock_pkgs=()
pkg_installed akmod-nvidia && lock_pkgs+=(akmod-nvidia)
while IFS= read -r p; do [[ -n "$p" ]] && lock_pkgs+=("$p"); done < <(rpm -qa --qf '%{NAME}\n' 'xorg-x11-drv-nvidia*' | sort -u)
[[ ${#lock_pkgs[@]} -gt 0 ]] && versionlock_installed "${lock_pkgs[@]}"

missing_kernels=()
for moddir in /lib/modules/*/; do
  kernel="$(basename "$moddir")"
  [[ -e "/boot/vmlinuz-$kernel" ]] || continue
  modinfo -k "$kernel" nvidia >/dev/null 2>&1 || missing_kernels+=("$kernel")
done
[[ ${#missing_kernels[@]} -eq 0 ]] || warn "nvidia module missing for installed kernels: ${missing_kernels[*]}"

warn "reboot required: nvidia driver, kernel args, and modprobe options only take effect after reboot"
