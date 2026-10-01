#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd findmnt mount umount mountpoint mktemp btrfs restorecon

ensure_pkg snapper libdnf5-plugin-actions

if [[ ! -f /etc/snapper/configs/root ]]; then
  log "creating snapper config: root"
  root snapper -c root create-config /
  [[ -f /etc/snapper/configs/root ]] || die "snapper config not created: root"
fi

snapper_config_value() {
  local key="$1" line
  line="$(root grep -E "^${key}=" /etc/snapper/configs/root 2>/dev/null | tail -n1)"
  line="${line#*=}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "$line"
}

ensure_snapper_setting() {
  local key="$1" val="$2"
  [[ "$(snapper_config_value "$key")" == "$val" ]] && { log "snapper $key=$val"; return 0; }
  log "setting snapper $key=$val"
  root snapper -c root set-config "$key=$val"
  [[ "$(snapper_config_value "$key")" == "$val" ]] || die "snapper config not applied: $key=$val"
}

ensure_snapper_setting NUMBER_LIMIT 10
ensure_snapper_setting NUMBER_LIMIT_IMPORTANT 10
ensure_snapper_setting TIMELINE_CREATE no

ensure_root_file "$ROOT/etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions" /etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions

assert_file_contains /etc/dnf/libdnf5-plugins/actions.conf 'enabled[[:space:]]*=[[:space:]]*1'

ensure_system_unit enabled snapper-cleanup.timer

assert "/.snapshots exists" test -d /.snapshots

NIX_PRE_VEKRONA=/nix.pre-vekrona
NIX_MIGRATED_MARKER=/nix/.vekrona-migrated

nix_source() { findmnt -no SOURCE /nix 2>/dev/null || true; }
nix_mounted_from_subvol() { [[ "$(nix_source)" == *"[/nix]" ]]; }

remove_nix_pre_vekrona() {
  [[ -e "$NIX_MIGRATED_MARKER" ]] || die "$NIX_PRE_VEKRONA present but $NIX_MIGRATED_MARKER missing, resolve manually"
  log "removing leftover: $NIX_PRE_VEKRONA"
  root rm -rf --one-file-system "$NIX_PRE_VEKRONA"
}

unit_exists() { systemctl cat "$1" >/dev/null 2>&1; }

stop_nix_daemon_units() {
  local u
  for u in nix-daemon.socket nix-daemon.service; do
    unit_exists "$u" || { log "unit not present: $u"; continue; }
    if [[ "$(systemctl is-active "$u" 2>/dev/null || true)" == active ]]; then
      log "stopping unit: $u"
      root systemctl stop "$u"
    else
      log "unit already inactive: $u"
    fi
    [[ "$(systemctl is-active "$u" 2>/dev/null || true)" != active ]] || die "unit still active: $u"
  done
}

ensure_nix_subvolume() {
  if mountpoint -q /nix && nix_mounted_from_subvol; then
    if [[ -e "$NIX_PRE_VEKRONA" ]]; then
      remove_nix_pre_vekrona
    else
      log "/nix already mounted from subvolume nix"
    fi
    return 0
  fi

  [[ ! -e /nix || -d /nix ]] || die "/nix exists and is not a directory"
  mountpoint -q /nix && die "/nix is mounted from something other than the nix subvolume: $(nix_source)"

  pkg_installed nix-daemon && stop_nix_daemon_units

  if [[ -d /nix && -n "$(ls -A /nix 2>/dev/null)" && ! -e "$NIX_PRE_VEKRONA" ]]; then
    log "moving existing /nix aside: $NIX_PRE_VEKRONA"
    root mv /nix "$NIX_PRE_VEKRONA"
  fi

  local top
  top="$(mktemp -d)"

  cleanup_nix_top() {
    if mountpoint -q "$top" 2>/dev/null; then
      root umount "$top" || warn "failed to unmount $top"
    fi
    rmdir "$top" 2>/dev/null || true
  }
  trap cleanup_nix_top EXIT
  mount_btrfs_top_level "$top"

  if [[ -e "$NIX_PRE_VEKRONA" ]]; then
    btrfs_migrate_dir_into_subvolume "$top/nix" "$NIX_PRE_VEKRONA"
  else
    btrfs_migrate_dir_into_subvolume "$top/nix"
  fi

  cleanup_nix_top
  trap - EXIT

  root mkdir -p /nix
  ensure_fstab_entry /nix "$(fstab_line_for_subvol /home /nix nix)"
  root systemctl daemon-reload
  root mount /nix
  nix_mounted_from_subvol || die "/nix not mounted from subvolume nix after mount"
  root restorecon -R /nix

  [[ -e "$NIX_PRE_VEKRONA" ]] && remove_nix_pre_vekrona

  pkg_installed nix-daemon && ensure_system_unit_active nix-daemon.service
  return 0
}

ensure_nix_subvolume

assert "/nix mounted from subvolume nix" nix_mounted_from_subvol
