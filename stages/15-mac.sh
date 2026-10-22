#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/facetimehd.sh"

require_cmd rpm dnf modinfo ip curl sort

NETWORK_PROBE_URL=https://mirrors.rpmfusion.org/
AKMOD_WL_MIN_FOR_KERNEL_7_2=6.30.223.271-63
AKMODS_CACHE_DIR=/var/cache/akmods
AKMODS_LOG=/var/log/akmods/akmods.log
SLEEP_HOOK_NAME=vekrona-brcmfmac-resume
REBOOT_PENDING_DIR=/run/vekrona-reboot-pending

target_kver="$(uname -r)"

version_at_least() {
  local have="$1" want="$2"
  [[ "$(printf '%s\n' "$want" "$have" | sort -V | head -n1)" == "$want" ]]
}

kernel_needs_recent_akmod_wl() { version_at_least "${target_kver%%-*}" 7.2; }

wl_module_built() { modinfo -k "$target_kver" wl >/dev/null 2>&1; }

wl_module_loaded() { [[ -d /sys/module/wl ]]; }

installed_akmod_wl_version() { rpm -q akmod-wl --qf '%{VERSION}-%{RELEASE}'; }

network_unreachable_hint() {
  local cause="$1" hint
  hint="no network ($cause), but this stage needs dnf and downloads."
  if has_broadcom_wl_wifi && ! wl_module_loaded; then
    hint+=" This MacBook's BCM4360 Wi-Fi has no driver until this stage builds wl."
  fi
  hint+=" Connect Ethernet (Thunderbolt or USB adapter) or enable USB tethering on a phone, then re-run: ./install.sh 15-mac"
  printf '%s' "$hint"
}

require_network() {
  local probe_error
  [[ -n "$(ip route show default)" ]] || die "$(network_unreachable_hint 'no default route')"
  if ! probe_error="$(curl --fail --silent --show-error --head --connect-timeout 10 --max-time 20 --output /dev/null "$NETWORK_PROBE_URL" 2>&1)"; then
    die "$(network_unreachable_hint "cannot reach $NETWORK_PROBE_URL: $probe_error")"
  fi
  log "ok: network reachable ($NETWORK_PROBE_URL)"
}

ensure_kernel_devel_for_rebuilds() {
  ensure_target_kernel_devel
  ensure_pkg "kernel-devel-matched-$(newest_installed_kver)"
}

akmod_wl_builds_on_this_kernel() {
  ! kernel_needs_recent_akmod_wl || version_at_least "$(installed_akmod_wl_version)" "$AKMOD_WL_MIN_FOR_KERNEL_7_2"
}

ensure_akmod_wl() {
  ensure_pkg akmod-wl
  akmod_wl_builds_on_this_kernel && return 0
  log "upgrading akmod-wl: $(installed_akmod_wl_version) cannot build on kernel $target_kver"
  root dnf upgrade -y akmod-wl
  akmod_wl_builds_on_this_kernel \
    || die "akmod-wl $(installed_akmod_wl_version) cannot build on kernel $target_kver (kernel 7.2+ needs RPM Fusion akmod-wl >= $AKMOD_WL_MIN_FOR_KERNEL_7_2; older builds fail on the removed strncpy API) and the enabled repos offer nothing newer"
}

die_wl_build_failed() {
  local failed_log="" where="$AKMODS_LOG"
  if failed_log="$(newest_akmods_failure_log "$AKMODS_CACHE_DIR" wl "$target_kver")"; then
    where="$failed_log (all akmods activity: $AKMODS_LOG)"
    warn "last 60 lines of $failed_log"
    root tail -n 60 "$failed_log" >&2
  fi
  die "wl module failed to build for kernel $target_kver with akmod-wl $(installed_akmod_wl_version); build log: $where. Boot the previous kernel (grub menu) and hold the kernel with dnf versionlock until RPM Fusion fixes akmod-wl"
}

ensure_wl_module() {
  wait_for_running_akmods
  if wl_module_built; then
    log "ok: wl module present for kernel $target_kver"
    return 0
  fi
  build_akmods_for_target_kernel || die_wl_build_failed
  wl_module_built || die_wl_build_failed
  log "ok: wl module built for kernel $target_kver"
}

ensure_brcmfmac_resume_hook() {
  local hook_path="/etc/systemd/system-sleep/$SLEEP_HOOK_NAME"
  ensure_root_file "$ROOT/etc/systemd/system-sleep/$SLEEP_HOOK_NAME" "$hook_path" 0755
  [[ -x "$hook_path" ]] || die "sleep hook is not executable: $hook_path"
}

# Installs a modprobe drop-in from etc/modprobe.d. A changed one reaches the modules only at the next boot, and /run is
# empty after a boot, so a marker there says "changed since boot" without comparing file times against a clock that can
# be stepped.
ensure_modprobe_dropin() {
  local name="$1" dst="/etc/modprobe.d/$1" changed=1
  if root_file_current "$ROOT/etc/modprobe.d/$name" "$dst" 0644; then changed=0; fi
  ensure_root_file "$ROOT/etc/modprobe.d/$name" "$dst"
  if [[ $changed -eq 1 ]]; then
    root install -d "$REBOOT_PENDING_DIR"
    root touch "$REBOOT_PENDING_DIR/$name"
  fi
}

reboot_pending_reasons() {
  local marker
  for marker in "$REBOOT_PENDING_DIR"/*; do
    if [[ -e "$marker" ]]; then echo "/etc/modprobe.d/${marker##*/} changed since boot"; fi
  done
  if has_broadcom_wl_wifi && ! wl_module_loaded; then echo "wl module is not loaded"; fi
  if has_facetime_hd_camera && [[ ! -d /sys/module/facetimehd ]]; then echo "facetimehd module is not loaded"; fi
}

require_network

if has_broadcom_wl_wifi || has_facetime_hd_camera; then
  die_if_secure_boot_blocks_akmods
  ensure_kernel_devel_for_rebuilds
fi

if has_broadcom_wl_wifi; then
  ensure_akmod_wl
  ensure_modprobe_dropin vekrona-broadcom-wl.conf
  ensure_wl_module
fi

if has_brcmfmac_43602; then
  ensure_brcmfmac_resume_hook
fi

if has_apple_gmux_dual_gpu; then
  ensure_modprobe_dropin vekrona-apple-gmux.conf
fi

if has_facetime_hd_camera; then
  ensure_facetimehd
fi

ensure_pkg libva-intel-driver

if is_macbookpro12_1; then
  ensure_modprobe_dropin vekrona-mbp12-audio.conf
fi

warn "fans run on firmware defaults: mbpfan is not packaged for Fedora 44, so no fan control is installed"

mapfile -t reboot_reasons < <(reboot_pending_reasons)
if [[ ${#reboot_reasons[@]} -gt 0 ]]; then
  for reason in "${reboot_reasons[@]}"; do warn "$reason"; done
  warn "reboot required: Apple hardware drivers and modprobe options only take effect after reboot"
fi
