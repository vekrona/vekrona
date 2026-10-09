#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

ensure_root_tree "$VEKRONA_ROOT/lib" "$VEKRONA_SYSTEM_DIR/lib"
ensure_root_tree "$VEKRONA_ROOT/libexec" "$VEKRONA_SYSTEM_DIR/libexec"
for script in "${VEKRONA_SYSTEM_BIN[@]}"; do
  ensure_root_file "$VEKRONA_ROOT/bin/$script" "$VEKRONA_SYSTEM_DIR/bin/$script" 0755
done
# lib/common.sh finds this repo file relative to its own checkout, which for the root-owned copy is VEKRONA_SYSTEM_DIR.
ensure_root_file "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" "$VEKRONA_SYSTEM_DIR/etc/yum.repos.d/1password.repo"
root_restorecon "$VEKRONA_SYSTEM_DIR"

for unit in "$VEKRONA_ROOT"/etc/systemd/system/vekrona-update-*; do
  ensure_system_unit_file "$unit"
done
for rule in "$VEKRONA_ROOT"/etc/polkit-1/rules.d/50-vekrona-*.rules; do
  ensure_root_file "$rule" "/etc/polkit-1/rules.d/${rule##*/}"
done
ensure_system_unit --now enabled vekrona-update-check.timer
ensure_system_unit enabled vekrona-update-post.service

ensure_root_file "$VEKRONA_ROOT/etc/greetd/config.toml" /etc/greetd/config.toml
ensure_root_file "$VEKRONA_ROOT/etc/geoclue/conf.d/90-vekrona.conf" /etc/geoclue/conf.d/90-vekrona.conf

STALE_TUIGREET_TMPFILES=/etc/tmpfiles.d/vekrona-tuigreet.conf
if [[ -e "$STALE_TUIGREET_TMPFILES" ]]; then
  ensure_root_file_absent "$STALE_TUIGREET_TMPFILES"
  log "regenerating initramfs images: dracut copies /etc/tmpfiles.d into them"
  root dracut --force --regenerate-all
fi

ensure_root_file "$VEKRONA_ROOT/etc/systemd/system/greetd.service.d/vekrona-tuigreet-cache.conf" /etc/systemd/system/greetd.service.d/vekrona-tuigreet-cache.conf
root systemctl daemon-reload
root install -d -m 0755 -o greetd -g greetd /var/cache/tuigreet
assert "tuigreet cache dir exists" test -d /var/cache/tuigreet

ensure_root_file "$VEKRONA_ROOT/etc/vekrona/errors-mute.d/10-vendor-noise.conf" /etc/vekrona/errors-mute.d/10-vendor-noise.conf
LOGIND_DROPINS=(/etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/logind.conf.d/vekrona-idle.conf)
logind_dropins_fingerprint() {
  local f
  for f in "${LOGIND_DROPINS[@]}"; do
    if [[ -e "$f" ]]; then cksum <"$f"; else echo absent; fi
  done
}
logind_before="$(logind_dropins_fingerprint)"
for dropin in "${LOGIND_DROPINS[@]}"; do
  ensure_root_file "$VEKRONA_ROOT/etc/systemd/logind.conf.d/${dropin##*/}" "$dropin"
done
if [[ "$(logind_dropins_fingerprint)" != "$logind_before" ]]; then
  # A reload re-reads IdleAction but logind arms its idle timer only when it starts, so the new action would wait for a reboot.
  log "logind drop-ins changed: restarting systemd-logind (sessions stay up)"
  root systemctl restart systemd-logind
fi
ensure_root_file "$VEKRONA_ROOT/etc/systemd/sleep.conf.d/vekrona.conf" /etc/systemd/sleep.conf.d/vekrona.conf
ensure_root_file "$VEKRONA_ROOT/etc/systemd/oomd.conf.d/vekrona.conf" /etc/systemd/oomd.conf.d/vekrona.conf
ensure_utc_rtc
USB_AUTOSUSPEND_DROPIN=/etc/modprobe.d/vekrona-usb-autosuspend.conf
usb_autosuspend_dropin_fingerprint() { if [[ -e "$USB_AUTOSUSPEND_DROPIN" ]]; then cksum <"$USB_AUTOSUSPEND_DROPIN"; else echo absent; fi; }
usb_dropin_before="$(usb_autosuspend_dropin_fingerprint)"
if wants_usb_autosuspend_dropin; then
  ensure_root_file "$VEKRONA_ROOT/etc/modprobe.d/vekrona-usb-autosuspend.conf" "$USB_AUTOSUSPEND_DROPIN"
else
  ensure_root_file_absent "$USB_AUTOSUSPEND_DROPIN"
fi
if [[ "$(usb_autosuspend_dropin_fingerprint)" != "$usb_dropin_before" ]]; then
  warn "usb-autosuspend drop-in changed: takes effect after reboot"
fi

if grep -qE '^[[:space:]]*deny[[:space:]]*=' /etc/security/faillock.conf 2>/dev/null; then
  assert_file_contains /etc/security/faillock.conf '^[[:space:]]*deny[[:space:]]*=[[:space:]]*10[[:space:]]*$'
else
  ensure_line /etc/security/faillock.conf "deny = 10"
fi

ensure_user_in_group input

ensure_root_file "$VEKRONA_ROOT/etc/modules-load.d/vekrona-uinput.conf" /etc/modules-load.d/vekrona-uinput.conf
root modprobe uinput
assert "uinput module loaded" grep -q '^uinput ' /proc/modules
assert "xremap udev rule installed" test -f /usr/lib/udev/rules.d/00-xremap-input.rules

ensure_root_file_absent /etc/udev/rules.d/70-vekrona-dgpu.rules
root udevadm control --reload
root udevadm trigger --settle --sysname-match=uinput

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
