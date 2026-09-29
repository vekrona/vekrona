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

root systemctl daemon-reload
