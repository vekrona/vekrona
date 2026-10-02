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

# akmod-nvidia's posttrans starts a background akmods build; every akmods run holds this lock, so wait for it
# instead of queueing a redundant rebuild behind it.
AKMODS_LOCK=/run/akmods/akmods.lock
AKMODS_LOCK_TIMEOUT_STATUS=1 # flock -w exits 1 on timeout, so any other status is a different failure
root install -d -m 0755 "$(dirname "$AKMODS_LOCK")"
lock_status=0
root flock -w 900 "$AKMODS_LOCK" true || lock_status=$?
case "$lock_status" in
  0) ;;
  "$AKMODS_LOCK_TIMEOUT_STATUS") die "timed out after 900 s waiting for a running akmods build (lock $AKMODS_LOCK)" ;;
  *) die "flock on $AKMODS_LOCK failed with status $lock_status" ;;
esac

if [[ "$(nvidia_module_license "$target_kver")" == NVIDIA ]]; then
  log "ok: proprietary nvidia module already built for $target_kver"
else
  log "building the proprietary nvidia module for $target_kver"
  root akmods --rebuild --kernels "$target_kver" || die "akmods failed, see /var/log/akmods/akmods.log"
fi

nvidia_problem="$(nvidia_module_problem "$target_kver")"
[[ -z "$nvidia_problem" ]] || die "$nvidia_problem; see /var/log/akmods/akmods.log"
log "ok: nvidia module for $target_kver is proprietary (license NVIDIA)"

nvidia_version="$(modinfo -k "$target_kver" -F version nvidia)"
[[ "${nvidia_version%%.*}" -ge 615 ]] || die "unexpected nvidia module version: $nvidia_version (expected >= 615)"
log "ok: nvidia module version $nvidia_version"

# RPM Fusion's dracut config omits nvidia from the initramfs; without it the LUKS prompt and the greeter have no display.
ensure_root_file "$ROOT/etc/dracut.conf.d/99-nvidia-dracut.conf" "$DRACUT_NVIDIA_CONF"

# New kernels get their initramfs from kernel-install before the asynchronous akmods@<kver> build exists.
ensure_root_file "$ROOT/etc/systemd/system/akmods@.service.d/vekrona-dracut.conf" /etc/systemd/system/akmods@.service.d/vekrona-dracut.conf
root systemctl daemon-reload
akmods_dropin_active "$target_kver" || die "akmods@$target_kver.service does not regenerate the initramfs after its build"

if initramfs_needs_nvidia_regen "$target_kver"; then
  log "regenerating initramfs for $target_kver"
  root dracut -f --kver "$target_kver"
  initramfs_has_nvidia "$target_kver" || die "initramfs for $target_kver still lacks nvidia after dracut"
else
  log "ok: initramfs for $target_kver contains nvidia and is newer than the module and its config"
fi

mapfile -t kernel_args < <(nvidia_kernel_args)
ensure_kernel_arg "${kernel_args[@]}"

modprobe_option_active() {
  local active
  active="$(grep -rhE '^[[:space:]]*[^#[:space:]]' /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null || true)"
  grep -qE -- "$1" <<<"$active"
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

for kernel in $(installed_kvers); do
  problem="$(nvidia_module_problem "$kernel")"
  [[ -z "$problem" ]] || warn "$problem"
done

warn "reboot required: nvidia driver, kernel args, and modprobe options only take effect after reboot"
