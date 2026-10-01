#!/usr/bin/env bash

FACETIMEHD_VERSION=0.7.2
FACETIMEHD_DKMS_VERSION=0.7.0.1
FACETIMEHD_URL="https://github.com/patjak/facetimehd/archive/refs/tags/$FACETIMEHD_VERSION.tar.gz"
FACETIMEHD_SHA256=ed4ca0a1388451c356c713957a9a597a5d625956d41a0dbcd618d04e12675a86
FACETIMEHD_SRC_DIR="/usr/src/facetimehd-$FACETIMEHD_DKMS_VERSION"
FACETIMEHD_SRC_STAMP="$FACETIMEHD_SRC_DIR/.vekrona-sha256"

FACETIMEHD_FIRMWARE_COMMIT=60ee21228d9ca00a7bd84fdaefaff00a81f1db91
FACETIMEHD_FIRMWARE_URL="https://github.com/patjak/facetimehd-firmware/archive/$FACETIMEHD_FIRMWARE_COMMIT.tar.gz"
FACETIMEHD_FIRMWARE_SHA256=8a991a516056c0733d81e3dd0979cac0a71b565209390d266df84b47679d38e4
FACETIMEHD_FIRMWARE_BIN_SHA256=240ef2e991f1d089d8228ce11d92b66bfa4b3d7289ec4fee228b64a713024330
FACETIMEHD_FIRMWARE_BIN=/usr/lib/firmware/facetimehd/firmware.bin

facetimehd_source_is_current() {
  [[ -f "$FACETIMEHD_SRC_STAMP" && "$(<"$FACETIMEHD_SRC_STAMP")" == "$FACETIMEHD_SHA256" ]]
}

facetimehd_dkms_registered() {
  [[ -n "$(dkms status -m facetimehd -v "$FACETIMEHD_DKMS_VERSION")" ]]
}

install_facetimehd_source() {
  local tmp="$1" unpacked dkms_version
  fetch_pinned "$FACETIMEHD_URL" "$FACETIMEHD_SHA256" "$tmp/src.tar.gz"
  tar -xzf "$tmp/src.tar.gz" -C "$tmp"
  unpacked="$tmp/facetimehd-$FACETIMEHD_VERSION"
  dkms_version="$(sed -n 's/^PACKAGE_VERSION=//p' "$unpacked/dkms.conf")"
  [[ "$dkms_version" == "$FACETIMEHD_DKMS_VERSION" ]] \
    || die "facetimehd $FACETIMEHD_VERSION declares dkms version '$dkms_version', expected $FACETIMEHD_DKMS_VERSION"
  if facetimehd_dkms_registered; then
    root dkms remove -m facetimehd -v "$FACETIMEHD_DKMS_VERSION" --all
  fi
  root rm -rf "$FACETIMEHD_SRC_DIR"
  log "installing: $FACETIMEHD_SRC_DIR"
  root cp -a "$unpacked" "$FACETIMEHD_SRC_DIR"
  printf '%s\n' "$FACETIMEHD_SHA256" | root tee "$FACETIMEHD_SRC_STAMP" >/dev/null
  facetimehd_source_is_current || die "facetimehd source stamp not written: $FACETIMEHD_SRC_STAMP"
}

ensure_facetimehd_source() {
  facetimehd_source_is_current && { log "up to date: $FACETIMEHD_SRC_DIR"; return 0; }
  with_scratch_dir install_facetimehd_source
}

facetimehd_dkms_status() {
  dkms status -m facetimehd -v "$FACETIMEHD_DKMS_VERSION" -k "$1"
}

ensure_facetimehd_dkms_built() {
  local kver="$1" status
  if ! facetimehd_dkms_registered; then
    log "dkms add: facetimehd $FACETIMEHD_DKMS_VERSION"
    root dkms add -m facetimehd -v "$FACETIMEHD_DKMS_VERSION"
  fi
  status="$(facetimehd_dkms_status "$kver")"
  [[ "$status" == *": installed"* ]] && { log "ok: facetimehd dkms installed for $kver"; return 0; }
  log "dkms build/install: facetimehd for $kver"
  root dkms build -m facetimehd -v "$FACETIMEHD_DKMS_VERSION" -k "$kver"
  root dkms install -m facetimehd -v "$FACETIMEHD_DKMS_VERSION" -k "$kver"
  status="$(facetimehd_dkms_status "$kver")"
  [[ "$status" == *": installed"* ]] || die "facetimehd dkms module not installed for $kver: $status"
}

facetimehd_firmware_is_current() {
  [[ -f "$FACETIMEHD_FIRMWARE_BIN" ]] \
    && [[ "$(sha256sum "$FACETIMEHD_FIRMWARE_BIN" | awk '{print $1}')" == "$FACETIMEHD_FIRMWARE_BIN_SHA256" ]]
}

install_facetimehd_firmware() {
  local tmp="$1" built actual
  fetch_pinned "$FACETIMEHD_FIRMWARE_URL" "$FACETIMEHD_FIRMWARE_SHA256" "$tmp/firmware.tar.gz"
  tar -xzf "$tmp/firmware.tar.gz" -C "$tmp"
  built="$tmp/facetimehd-firmware-$FACETIMEHD_FIRMWARE_COMMIT"
  log "extracting facetimehd firmware from Apple's macOS update (large download)"
  make -C "$built"
  actual="$(sha256sum "$built/firmware.bin" | awk '{print $1}')"
  [[ "$actual" == "$FACETIMEHD_FIRMWARE_BIN_SHA256" ]] \
    || die "extracted firmware.bin sha256 mismatch (expected $FACETIMEHD_FIRMWARE_BIN_SHA256, got $actual)"
  root make -C "$built" install
  facetimehd_firmware_is_current || die "firmware missing or wrong sha256 after install: $FACETIMEHD_FIRMWARE_BIN"
}

ensure_facetimehd_firmware() {
  facetimehd_firmware_is_current && { log "up to date: $FACETIMEHD_FIRMWARE_BIN"; return 0; }
  if [[ -e "$FACETIMEHD_FIRMWARE_BIN" ]]; then
    warn "replacing $FACETIMEHD_FIRMWARE_BIN: sha256 differs from the pinned $FACETIMEHD_FIRMWARE_BIN_SHA256"
  fi
  with_scratch_dir install_facetimehd_firmware
}

ensure_facetimehd() {
  local target_kver
  target_kver="$(uname -r)"
  require_cmd rpm dnf modinfo
  ensure_pkg dkms gcc make curl xz cpio
  require_cmd dkms
  ensure_target_kernel_devel
  ensure_facetimehd_source
  ensure_facetimehd_dkms_built "$target_kver"
  ensure_facetimehd_firmware
  modinfo -k "$target_kver" facetimehd >/dev/null 2>&1 || die "facetimehd module not built for $target_kver"
  log "ok: facetimehd module and firmware present for kernel $target_kver"
}
