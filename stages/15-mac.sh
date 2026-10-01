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
MODPROBE_DROPINS=(
  /etc/modprobe.d/vekrona-broadcom-wl.conf
  /etc/modprobe.d/vekrona-apple-gmux.conf
  /etc/modprobe.d/vekrona-mbp12-audio.conf
)

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

akmods_failure_log_for_wl() {
  local logs=("$AKMODS_CACHE_DIR"/wl/*-for-"$target_kver".failed.log)
  [[ -e "${logs[0]}" ]] && printf '%s' "${logs[0]}"
}

die_wl_build_failed() {
  local failed_log="" where="$AKMODS_LOG"
  if failed_log="$(akmods_failure_log_for_wl)"; then
    where="$failed_log (all akmods activity: $AKMODS_LOG)"
    warn "last 60 lines of $failed_log"
    root tail -n 60 "$failed_log" >&2
  fi
  die "wl module failed to build for kernel $target_kver with akmod-wl $(installed_akmod_wl_version); build log: $where. Boot the previous kernel (grub menu) and hold the kernel with dnf versionlock until RPM Fusion fixes akmod-wl"
}

ensure_wl_module() {
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

boot_time() { awk '/^btime/ {print $2}' /proc/stat; }

changed_since_boot() { [[ "$(stat -c %Y "$1")" -gt "$(boot_time)" ]]; }

reboot_pending_reasons() {
  local dropin
  for dropin in "${MODPROBE_DROPINS[@]}"; do
    if [[ -e "$dropin" ]] && changed_since_boot "$dropin"; then echo "$dropin changed since boot"; fi
  done
  if has_broadcom_wl_wifi && ! wl_module_loaded; then echo "wl module is not loaded"; fi
  if has_facetime_hd_camera && [[ ! -d /sys/module/facetimehd ]]; then echo "facetimehd module is not loaded"; fi
}

require_network

if has_broadcom_wl_wifi || has_facetime_hd_camera; then
  ensure_kernel_devel_for_rebuilds
fi

if has_broadcom_wl_wifi; then
  ensure_akmod_wl
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-broadcom-wl.conf" /etc/modprobe.d/vekrona-broadcom-wl.conf
  ensure_wl_module
fi

if has_brcmfmac_43602; then
  ensure_brcmfmac_resume_hook
fi

if has_apple_gmux_dual_gpu; then
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-apple-gmux.conf" /etc/modprobe.d/vekrona-apple-gmux.conf
fi

if has_facetime_hd_camera; then
  ensure_facetimehd
fi

ensure_pkg libva-intel-driver

if is_macbookpro12_1; then
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-mbp12-audio.conf" /etc/modprobe.d/vekrona-mbp12-audio.conf
fi

warn "fans run on firmware defaults: mbpfan is not packaged for Fedora 44, so no fan control is installed"

mapfile -t reboot_reasons < <(reboot_pending_reasons)
if [[ ${#reboot_reasons[@]} -gt 0 ]]; then
  for reason in "${reboot_reasons[@]}"; do warn "$reason"; done
  warn "reboot required: Apple hardware drivers and modprobe options only take effect after reboot"
fi
