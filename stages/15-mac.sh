#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/facetimehd.sh"

require_cmd rpm dnf modinfo

target_kver="$(uname -r)"

if has_broadcom_wl_wifi; then
  ensure_pkg akmod-wl
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-broadcom-wl.conf" /etc/modprobe.d/vekrona-broadcom-wl.conf
  build_akmods_for_target_kernel
  modinfo -k "$target_kver" wl >/dev/null 2>&1 \
    || die "akmod-wl failed to build for $target_kver; keep the previous kernel with dnf versionlock"
  log "ok: wl module present for kernel $target_kver"
fi

if has_apple_gmux_dual_gpu; then
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-apple-gmux.conf" /etc/modprobe.d/vekrona-apple-gmux.conf
fi

if has_facetime_hd_camera; then
  ensure_facetimehd
fi

ensure_pkg libva-intel-driver

if [[ "$(dmi_field product_name)" == "MacBookPro12,1" ]]; then
  ensure_root_file "$ROOT/etc/modprobe.d/vekrona-mbp12-audio.conf" /etc/modprobe.d/vekrona-mbp12-audio.conf
fi

warn "reboot required: Apple hardware drivers and modprobe options only take effect after reboot"
