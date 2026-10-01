#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/display-scale.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect_scale() {
  local label="$1" expected="$2" got
  shift 2
  got="$(panel_scale_for "$@")"
  [[ "$got" == "$expected" ]] || die "$label: expected scale $expected, got $got"
  log "ok: $label -> scale $expected"
}

expect_scale "13.3in 2560x1600 (MacBook Pro 13 Retina)" 2 2560 1600 286 179
expect_scale "15.4in 2880x1800 (MacBook Pro 15 Retina)" 2 2880 1800 331 207
expect_scale "13.3in 1440x900 (MacBook Air)" 1 1440 900 286 179
expect_scale "14in 1920x1080 laptop" 1 1920 1080 309 174
expect_scale "27in 3840x2160 monitor" 1 3840 2160 596 336

if panel_scale_for 0 1600 286 179 2>/dev/null; then die "zero width must be rejected"; fi
if panel_scale_for 2560 1600 abc 179 2>/dev/null; then die "non-numeric size must be rejected"; fi
log "ok: invalid dimensions rejected"

write_edid() {
  local file="$1" mm_w="$2" mm_h="$3" b escapes
  read -ra b <<<"$(printf '0 %.0s' {1..128})"
  b[1]=255; b[2]=255; b[3]=255; b[4]=255; b[5]=255; b[6]=255
  b[21]=$((mm_w / 10)); b[22]=$((mm_h / 10))
  b[54]=1; b[55]=1
  b[66]=$((mm_w & 255)); b[67]=$((mm_h & 255))
  b[68]=$(( ((mm_w >> 8) << 4) | (mm_h >> 8) ))
  escapes="$(printf '\\x%02x' "${b[@]}")"
  printf '%b' "$escapes" > "$file"
}

make_connector() {
  local name="$1" status="$2" mode="$3" mm_w="$4" mm_h="$5" dir="$DRM_SYSFS_ROOT/$1"
  mkdir -p "$dir"
  echo "$status" > "$dir/status"
  echo "$mode" > "$dir/modes"
  write_edid "$dir/edid" "$mm_w" "$mm_h"
}

DRM_SYSFS_ROOT="$work/drm"
HOME="$work/home"
SWAY_PANEL_SCALE_DROPIN="$HOME/.config/sway/config.d/vekrona-panel-scale.conf"

make_connector card1-eDP-1 connected 2880x1800 331 207
make_connector card1-DP-1 connected 3840x2160 596 336
ensure_internal_panel_scale
[[ "$(<"$SWAY_PANEL_SCALE_DROPIN")" == "output eDP-1 scale 2" ]] \
  || die "HiDPI eDP panel: unexpected drop-in: $(<"$SWAY_PANEL_SCALE_DROPIN")"
log "ok: HiDPI panel gets scale 2, external DP-1 ignored"

make_connector card1-eDP-1 connected 1440x900 286 179
ensure_internal_panel_scale
[[ "$(<"$SWAY_PANEL_SCALE_DROPIN")" == "output eDP-1 scale 1" ]] \
  || die "low-DPI eDP panel: unexpected drop-in: $(<"$SWAY_PANEL_SCALE_DROPIN")"
log "ok: re-run rewrites the drop-in for a low-DPI panel"

rm -rf "$DRM_SYSFS_ROOT/card1-eDP-1"
ensure_internal_panel_scale
[[ ! -e "$SWAY_PANEL_SCALE_DROPIN" ]] || die "drop-in must be removed when no internal panel is connected"
log "ok: no internal panel removes the drop-in"

make_connector card1-eDP-1 connected 2880x1800 331 207
: > "$DRM_SYSFS_ROOT/card1-eDP-1/edid"
if (ensure_internal_panel_scale) 2>/dev/null; then die "unreadable EDID must fail"; fi
log "ok: unreadable EDID fails loudly"
