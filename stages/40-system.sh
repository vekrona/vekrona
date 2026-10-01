#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

ensure_root_file "$VEKRONA_ROOT/etc/greetd/config.toml" /etc/greetd/config.toml

ensure_root_file "$VEKRONA_ROOT/etc/tmpfiles.d/vekrona-tuigreet.conf" /etc/tmpfiles.d/vekrona-tuigreet.conf
root systemd-tmpfiles --create /etc/tmpfiles.d/vekrona-tuigreet.conf
assert "tuigreet cache dir exists" test -d /var/cache/tuigreet

ensure_root_file "$VEKRONA_ROOT/etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf" /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf
ensure_root_file "$VEKRONA_ROOT/etc/systemd/oomd.conf.d/vekrona.conf" /etc/systemd/oomd.conf.d/vekrona.conf
ensure_root_file "$VEKRONA_ROOT/etc/modprobe.d/vekrona-usb-autosuspend.conf" /etc/modprobe.d/vekrona-usb-autosuspend.conf

if grep -qE '^[[:space:]]*deny[[:space:]]*=' /etc/security/faillock.conf 2>/dev/null; then
  assert_file_contains /etc/security/faillock.conf '^[[:space:]]*deny[[:space:]]*=[[:space:]]*10[[:space:]]*$'
else
  ensure_line /etc/security/faillock.conf "deny = 10"
fi

ensure_user_in_group input

ensure_root_file "$VEKRONA_ROOT/etc/modules-load.d/vekrona-uinput.conf" /etc/modules-load.d/vekrona-uinput.conf
root modprobe uinput
assert "uinput module loaded" bash -c "lsmod | grep -q '^uinput'"
assert "xremap udev rule installed" test -f /usr/lib/udev/rules.d/00-xremap-input.rules

root udevadm control --reload
root udevadm trigger --settle --sysname-match=uinput

ensure_root_file "$VEKRONA_ROOT/etc/udev/rules.d/70-vekrona-dgpu.rules" /etc/udev/rules.d/70-vekrona-dgpu.rules
root udevadm control --reload
root udevadm trigger --settle --subsystem-match=drm

if [[ -e /dev/dri/vekrona-dgpu ]]; then
  log "ok: /dev/dri/vekrona-dgpu exists"
else
  log "note: no /dev/dri/vekrona-dgpu (no matching DRM device at PCI 0000:01:00.0 or nvidia not loaded)"
fi

root systemctl daemon-reload

ensure_system_unit enabled tailscaled nix-daemon.service
ensure_system_unit_active tailscaled nix-daemon.service

tailscale_operator() { root tailscale debug prefs | jq -r '.OperatorUser // ""'; }

ensure_tailscale_operator() {
  local user="$1"
  [[ "$(tailscale_operator)" == "$user" ]] && { log "tailscale operator: $user"; return 0; }
  log "setting tailscale operator: $user"
  root tailscale set --operator="$user"
  [[ "$(tailscale_operator)" == "$user" ]] || die "tailscale operator not set to $user: run 'tailscale up' to log in, then re-run ./install.sh 40"
}

ensure_tailscale_operator "$VEKRONA_USER"
