#!/usr/bin/env bash

HIDPI_MIN_DPI=192
SWAY_PANEL_SCALE_DROPIN="$HOME/.config/sway/config.d/vekrona-panel-scale.conf"
DRM_SYSFS_ROOT=/sys/class/drm

panel_scale_for() {
  local px_w="$1" px_h="$2" mm_w="$3" mm_h="$4" v
  for v in "$px_w" "$px_h" "$mm_w" "$mm_h"; do
    [[ "$v" =~ ^[1-9][0-9]*$ ]] || { warn "panel_scale_for: invalid dimension '$v'"; return 1; }
  done
  if (( px_w * 254 >= HIDPI_MIN_DPI * mm_w * 10 )); then echo 2; else echo 1; fi
}

edid_physical_size_mm() {
  local edid="$1" b
  read -ra b -d "" < <(od -An -tu1 -v -N128 "$edid") || true
  [[ ${#b[@]} -eq 128 ]] || { warn "EDID too short: $edid"; return 1; }
  [[ "${b[*]:0:8}" == "0 255 255 255 255 255 255 0" ]] || { warn "EDID header invalid: $edid"; return 1; }
  local w=0 h=0
  if (( b[54] != 0 || b[55] != 0 )); then
    w=$(( b[66] | ((b[68] >> 4) << 8) ))
    h=$(( b[67] | ((b[68] & 15) << 8) ))
  fi
  if (( w == 0 || h == 0 )); then
    w=$(( b[21] * 10 ))
    h=$(( b[22] * 10 ))
  fi
  (( w > 0 && h > 0 )) || { warn "EDID reports no physical size: $edid"; return 1; }
  echo "$w $h"
}

internal_panel_connectors() {
  local c
  for c in "$DRM_SYSFS_ROOT"/card*-eDP-*; do
    [[ -e "$c/status" && "$(<"$c/status")" == connected ]] && echo "$c"
  done
  return 0
}

has_internal_panel() { [[ -n "$(internal_panel_connectors)" ]]; }

internal_panel_scale_line() {
  local connector="$1" name mode px_w px_h mm_w mm_h scale
  name="${connector##*/}"
  name="${name#card*-}"
  mode="$(head -n1 "$connector/modes")"
  [[ "$mode" =~ ^([0-9]+)x([0-9]+) ]] || { warn "no usable mode in $connector/modes"; return 1; }
  px_w="${BASH_REMATCH[1]}"
  px_h="${BASH_REMATCH[2]}"
  read -r mm_w mm_h < <(edid_physical_size_mm "$connector/edid") || return 1
  scale="$(panel_scale_for "$px_w" "$px_h" "$mm_w" "$mm_h")" || return 1
  echo "output ${name} scale ${scale}"
}

ensure_internal_panel_scale() {
  local connector line content=""
  if ! has_internal_panel; then
    log "no connected internal panel, $SWAY_PANEL_SCALE_DROPIN absent (ok)"
    rm -f "$SWAY_PANEL_SCALE_DROPIN"
    return 0
  fi
  while IFS= read -r connector; do
    line="$(internal_panel_scale_line "$connector")" || die "cannot derive display scale from $connector"
    content+="$line"$'\n'
  done < <(internal_panel_connectors)
  ensure_dir "$(dirname "$SWAY_PANEL_SCALE_DROPIN")"
  if [[ -f "$SWAY_PANEL_SCALE_DROPIN" && "$(<"$SWAY_PANEL_SCALE_DROPIN")" == "${content%$'\n'}" ]]; then
    log "up to date: $SWAY_PANEL_SCALE_DROPIN"
    return 0
  fi
  log "writing: $SWAY_PANEL_SCALE_DROPIN"
  printf '%s' "$content" > "$SWAY_PANEL_SCALE_DROPIN"
  [[ "$(<"$SWAY_PANEL_SCALE_DROPIN")" == "${content%$'\n'}" ]] || die "failed to write $SWAY_PANEL_SCALE_DROPIN"
}
