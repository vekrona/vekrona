#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

ensure_pkg snapper libdnf5-plugin-actions

if [[ ! -d /etc/snapper/configs/root ]]; then
  log "creating snapper config: root"
  root snapper -c root create-config /
  [[ -d /etc/snapper/configs/root ]] || die "snapper config not created: root"
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
