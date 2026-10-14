#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd rpm dnf5 grubby modinfo

target_kver="$(uname -r)"
ensure_target_kernel_devel

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

# RPM Fusion's akmod builds the Open module for Turing+ GPUs unless this macro turns its detection off.
ensure_root_file "$ROOT/etc/rpm/macros.nvidia-kmod" /etc/rpm/macros.nvidia-kmod

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

ensure_pkg libva-nvidia-driver

if pkg_installed cuda-toolkit; then
  root dnf upgrade -y cuda-toolkit
fi

require_cmd akmods dracut lsinitrd flock

# akmod-nvidia's posttrans starts a background akmods build.
wait_for_akmods_idle
ensure_nvidia_module "$target_kver"

nvidia_version="$(modinfo -k "$target_kver" -F version nvidia)"
[[ "${nvidia_version%%.*}" -ge 615 ]] || die "unexpected nvidia module version: $nvidia_version (expected >= 615)"
log "ok: nvidia module version $nvidia_version"

# RPM Fusion's dracut config omits nvidia from the initramfs; without it the LUKS prompt and the greeter have no display.
ensure_root_file "$ROOT/etc/dracut.conf.d/99-nvidia-dracut.conf" "$DRACUT_NVIDIA_CONF"

# New kernels get their initramfs from kernel-install before the asynchronous akmods@<kver> build exists.
ensure_root_file "$ROOT/etc/systemd/system/akmods@.service.d/vekrona-dracut.conf" /etc/systemd/system/akmods@.service.d/vekrona-dracut.conf
root systemctl daemon-reload
akmods_dropin_active "$target_kver" || die "akmods@$target_kver.service does not regenerate the initramfs after its build"

# The proprietary module defaults NVreg_UseKernelSuspendNotifiers to 1 but only the open modules honour it; the
# nvidia-suspend/resume units skip themselves unless it is 0, so video memory preservation then fails with -EIO.
# nvidia loads from the initramfs, so this goes in before the regeneration below, which bakes it into the image.
ensure_root_file "$ROOT/etc/modprobe.d/vekrona-nvidia.conf" "$NVIDIA_MODPROBE_CONF"

ensure_nvidia_initramfs "$target_kver"

mapfile -t kernel_args < <(nvidia_kernel_args)
ensure_kernel_arg "${kernel_args[@]}"

ensure_system_unit enabled nvidia-suspend nvidia-resume nvidia-hibernate nvidia-suspend-then-hibernate

# nvidia-powerd is the Dynamic Boost daemon for laptops; on a desktop it only logs "UnSupported CPU" every boot.
if is_laptop; then
  log "laptop: leaving nvidia-powerd at the package default"
else
  ensure_system_unit --now disabled nvidia-powerd.service
fi

lock_pkgs=()
pkg_installed akmod-nvidia && lock_pkgs+=(akmod-nvidia)
while IFS= read -r p; do [[ -n "$p" ]] && lock_pkgs+=("$p"); done < <(rpm -qa --qf '%{NAME}\n' 'xorg-x11-drv-nvidia*' | sort -u)
[[ ${#lock_pkgs[@]} -gt 0 ]] && versionlock_installed "${lock_pkgs[@]}"

for kernel in $(installed_kvers); do
  problem="$(nvidia_module_problem "$kernel")"
  [[ -z "$problem" ]] || warn "$problem"
done

warn "reboot required: nvidia driver, kernel args, and modprobe options only take effect after reboot"
