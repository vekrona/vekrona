#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
tool="$ROOT/bin/vekrona-gpu-env"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

NVIDIA=0x10de
INTEL=0x8086

new_machine() {
  rm -rf "$scratch/root"
  mkdir -p "$scratch/root/sys/class/drm" "$scratch/root/sys/module"
  export VEKRONA_SYSFS_ROOT="$scratch/root"
}

add_card() {
  local card="$1" pci="$2" vendor="$3" dev="$scratch/root/sys/bus/pci/devices/$2"
  mkdir -p "$dev"
  echo "$vendor" > "$dev/vendor"
  mkdir -p "$scratch/root/sys/class/drm/$card"
  ln -s "../../../bus/pci/devices/$pci" "$scratch/root/sys/class/drm/$card/device"
}

add_connector() {
  local name="$1" status="$2"
  mkdir -p "$scratch/root/sys/class/drm/$name"
  echo "$status" > "$scratch/root/sys/class/drm/$name/status"
}

nvidia_driver_loaded() { mkdir "$scratch/root/sys/module/nvidia_drm"; }

expect_env() {
  local description="$1" expected="$2" got
  got="$("$tool" 2>"$scratch/stderr")" || die "$description: tool failed: $(cat "$scratch/stderr")"
  [[ "$got" == "$expected" ]] || die "$description: expected '$expected', got '$got'"
  log "ok: $description"
}

new_machine
add_card card0 0000:00:02.0 "$INTEL"
add_card card1 0000:01:00.0 "$NVIDIA"
add_connector card0-DP-1 disconnected
add_connector card1-DP-1 connected
add_connector card1-DP-2 disconnected
add_connector card1-Writeback-1 unknown
nvidia_driver_loaded
expect_env "monitor on the NVIDIA card with the driver loaded pins wlroots to it" "export WLR_DRM_DEVICES=/dev/dri/card1"

new_machine
add_card card0 0000:00:02.0 "$INTEL"
add_card card1 0000:01:00.0 "$NVIDIA"
add_connector card0-eDP-1 connected
add_connector card0-DP-1 disconnected
add_connector card1-DP-1 disconnected
add_connector card1-Writeback-1 unknown
nvidia_driver_loaded
expect_env "Optimus laptop with the panel on the Intel card is left to wlroots" ""

new_machine
add_card card0 0000:00:02.0 "$INTEL"
add_card card1 0000:01:00.0 "$NVIDIA"
add_connector card0-HDMI-A-1 connected
add_connector card1-DP-1 disconnected
nvidia_driver_loaded
expect_env "desktop with the monitor on the iGPU is left to wlroots" ""

new_machine
add_card card0 0000:00:02.0 "$INTEL"
add_card card1 0000:01:00.0 "$NVIDIA"
add_connector card1-DP-1 connected
expect_env "NVIDIA driver not loaded (nouveau era) is left to wlroots" ""

new_machine
add_card card0 0000:00:02.0 "$INTEL"
add_card card1 0000:01:00.0 "$NVIDIA"
add_connector card0-HDMI-A-1 connected
add_connector card1-DP-1 connected
nvidia_driver_loaded
expect_env "monitors on both cards are left to wlroots" ""

new_machine
add_card card0 0000:01:00.0 "$NVIDIA"
add_card card1 0000:02:00.0 "$NVIDIA"
add_connector card0-DP-1 connected
add_connector card1-DP-1 connected
nvidia_driver_loaded
expect_env "monitors on two NVIDIA cards are left to wlroots" ""

new_machine
add_card card2 0000:01:00.0 "$NVIDIA"
add_connector card2-DP-1 connected
mkdir -p "$scratch/root/proc/driver/nvidia"
echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module" > "$scratch/root/proc/driver/nvidia/version"
expect_env "driver detected through /proc/driver/nvidia/version, card number taken from sysfs" "export WLR_DRM_DEVICES=/dev/dri/card2"

new_machine
nvidia_driver_loaded
expect_env "no DRM devices at all is left to wlroots" ""

rm -rf "$scratch/root/sys/class/drm"
expect_env "no /sys/class/drm is left to wlroots" ""

new_machine
add_card card1 0000:01:00.0 "lizard"
add_connector card1-DP-1 connected
nvidia_driver_loaded
expect_env "garbage vendor file is left to wlroots" ""
grep -q "unexpected content" "$scratch/stderr" || die "garbage vendor must be warned about on stderr"
log "ok: garbage vendor file is warned about"

new_machine
add_connector card1-DP-1 connected
nvidia_driver_loaded
expect_env "connector without a device link is left to wlroots" ""
grep -q "cannot read" "$scratch/stderr" || die "missing vendor file must be warned about on stderr"
log "ok: missing vendor file is warned about"

if "$tool" --bogus 2>/dev/null; then die "unknown argument must be rejected"; fi
log "ok: unknown argument rejected"

# What Sway actually receives: config/sway/environment is sourced by start-sway's shell, and its variables must reach sway.
sway_sees() {
  VEKRONA_SYSFS_ROOT="$VEKRONA_SYSFS_ROOT" PATH="$ROOT/bin:$PATH" HOME="$scratch/home" \
    sh -c 'set -a; . "$1"; set +a; sh -c "echo \"\${WLR_DRM_DEVICES-unset}\""' sh "$ROOT/config/sway/environment" 2>/dev/null
}

new_machine
add_card card1 0000:01:00.0 "$NVIDIA"
add_connector card1-DP-1 connected
nvidia_driver_loaded
[[ "$(sway_sees)" == /dev/dri/card1 ]] || die "config/sway/environment must export WLR_DRM_DEVICES to sway, got '$(sway_sees)'"
log "ok: config/sway/environment hands WLR_DRM_DEVICES to the child process"

rm -rf "$scratch/root/sys/module/nvidia_drm"
[[ "$(sway_sees)" == unset ]] || die "config/sway/environment must leave WLR_DRM_DEVICES unset, got '$(sway_sees)'"
log "ok: config/sway/environment leaves WLR_DRM_DEVICES unset when the tool prints nothing"
