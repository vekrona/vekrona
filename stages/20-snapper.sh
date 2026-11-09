#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

require_cmd findmnt mount umount mountpoint mktemp btrfs restorecon chcon matchpathcon selinuxenabled journalctl lsattr chattr

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

# A VM image that a domain still uses cannot be copied into the subvolume: the copy would be half old and half new, and the domain would
# keep the old file open. Any active domain counts (running, paused, suspended). A libvirt that is not installed has no domains.
refuse_while_domains_active() {
  local active
  command -v virsh >/dev/null || return 0
  active="$(root virsh list --name)"
  [[ -z "${active//[[:space:]]/}" ]] || refuse "libvirt domains are active, shut them down and run this stage again: ${active//$'\n'/ }"
}

ensure_snapper_setting NUMBER_LIMIT 10
ensure_snapper_setting NUMBER_LIMIT_IMPORTANT 10
ensure_snapper_setting TIMELINE_CREATE no

# The actions file starts a script of the root-owned copy before and after every dnf transaction, so the copy comes first.
ensure_system_copy
ensure_root_file "$ROOT/etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions" /etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions

assert_file_contains /etc/dnf/libdnf5-plugins/actions.conf 'enabled[[:space:]]*=[[:space:]]*1'

ensure_system_unit --now enabled snapper-cleanup.timer

assert "/.snapshots exists" test -d /.snapshots

ensure_tmp_subvolume

# Snapper snapshots of root stop at a subvolume. The VM images, the package caches and the logs are the big, fast-changing files that
# a snapshot would otherwise pin, so each lives in a top-level subvolume of its own (see ensure_top_subvolume).
if ! btrfs_subvolume_mounted /var/lib/libvirt/images libvirt-images && directory_has_files /var/lib/libvirt/images; then refuse_while_domains_active; fi
log_moves=1
if btrfs_subvolume_mounted /var/log var-log; then log_moves=0; fi

ensure_top_subvolume libvirt-images /var/lib/libvirt/images root:root 0711
ensure_top_subvolume var-cache /var/cache root:root 0755
ensure_top_subvolume var-log /var/log root:root 0755
# journald still writes to the old files it holds open: a rotation makes it open new ones in the subvolume. It runs on every run, so that
# a run that stopped between the mount and here still switches journald on the next one.
root journalctl --flush --rotate
if ((log_moves)); then
  warn "/var/log moved to its subvolume: a daemon that keeps a log file open (auditd) still writes to the deleted old file until it restarts; reboot soon"
fi
