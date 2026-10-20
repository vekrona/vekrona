#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/firewall.sh"
source "$ROOT/lib/tailnet-ssh.sh"
source "$ROOT/lib/geoclue.sh"
source "$ROOT/lib/xremap.sh"

ensure_system_copy
root "$VEKRONA_SYSTEM_DIR/libexec/vekrona-update-seed"

for unit in "$VEKRONA_ROOT"/etc/systemd/system/vekrona-update-*; do
  ensure_system_unit_file "$unit"
done
for rule in "$VEKRONA_ROOT"/etc/polkit-1/rules.d/50-vekrona-*.rules; do
  ensure_root_file "$rule" "/etc/polkit-1/rules.d/${rule##*/}"
done
ensure_system_unit --now enabled vekrona-update-check.timer
ensure_system_unit enabled vekrona-update-post.service

ensure_root_file "$VEKRONA_ROOT/etc/greetd/config.toml" /etc/greetd/config.toml
# Only this user may use the weather app's geoclue access.
install_geoclue_conf() {
  local scratch="$1"
  render_geoclue_conf "$(id -u)" <"$VEKRONA_ROOT/etc/geoclue/conf.d/90-vekrona.conf" >"$scratch/90-vekrona.conf" \
    || die "etc/geoclue/conf.d/90-vekrona.conf has no users= line to set"
  ensure_root_file "$scratch/90-vekrona.conf" /etc/geoclue/conf.d/90-vekrona.conf
}
with_scratch_dir install_geoclue_conf
# Firefox's enterprise policies (Firefox comes from stage 30).
ensure_root_file "$VEKRONA_ROOT/config/firefox/policies.json" /usr/lib64/firefox/distribution/policies.json

STALE_TUIGREET_TMPFILES=/etc/tmpfiles.d/vekrona-tuigreet.conf
if [[ -e "$STALE_TUIGREET_TMPFILES" ]]; then
  ensure_root_file_absent "$STALE_TUIGREET_TMPFILES"
  log "regenerating initramfs images: dracut copies /etc/tmpfiles.d into them"
  dracut_locked --force --regenerate-all
fi

ensure_root_file "$VEKRONA_ROOT/etc/systemd/system/greetd.service.d/vekrona-tuigreet-cache.conf" /etc/systemd/system/greetd.service.d/vekrona-tuigreet-cache.conf
root systemctl daemon-reload
root install -d -m 0755 -o greetd -g greetd /var/cache/tuigreet
assert "tuigreet cache dir exists" test -d /var/cache/tuigreet

ensure_root_file "$VEKRONA_ROOT/etc/vekrona/errors-mute.d/10-vendor-noise.conf" /etc/vekrona/errors-mute.d/10-vendor-noise.conf
# Subscription-only login for any Claude Code install, whoever installed it.
ensure_root_file "$VEKRONA_ROOT/etc/claude-code/managed-settings.json" /etc/claude-code/managed-settings.json
# logind arms its idle timer only when it starts, so IdleAction needs a restart (sessions stay up), not a reload.
ensure_dropins_restarting systemd-logind "$VEKRONA_ROOT/etc/systemd/logind.conf.d" /etc/systemd/logind.conf.d vekrona-inhibit-delay.conf vekrona-idle.conf
ensure_root_file "$VEKRONA_ROOT/etc/systemd/sleep.conf.d/vekrona.conf" /etc/systemd/sleep.conf.d/vekrona.conf
ensure_dropins_restarting systemd-oomd "$VEKRONA_ROOT/etc/systemd/oomd.conf.d" /etc/systemd/oomd.conf.d vekrona.conf
ensure_root_file "$VEKRONA_ROOT/etc/systemd/coredump.conf.d/50-vekrona.conf" /etc/systemd/coredump.conf.d/50-vekrona.conf
# irqbalance spreads interrupts over cores, which a battery only pays for: laptops run without it.
if irqbalance_wanted; then
  ensure_dropins_restarting irqbalance.service "$VEKRONA_ROOT/etc/sysconfig" /etc/sysconfig irqbalance
  ensure_dropins_restarting irqbalance.service "$VEKRONA_ROOT/etc/systemd/system/irqbalance.service.d" /etc/systemd/system/irqbalance.service.d vekrona.conf
else
  ensure_system_unit --now disabled irqbalance.service
fi
# The PAM service and its environment file come first: sudo selects the service by name, and a missing one locks it out.
ensure_root_file "$VEKRONA_ROOT/etc/vekrona/sudo-session.env" /etc/vekrona/sudo-session.env
ensure_root_file "$VEKRONA_ROOT/etc/pam.d/vekrona-sudo" /etc/pam.d/vekrona-sudo
ensure_sudoers_dropin "$VEKRONA_ROOT/etc/sudoers.d/50-vekrona-sudo-pam-service"
ensure_root_file_absent /etc/sudoers.d/50-vekrona-no-pam-session # the earlier "Defaults !pam_session"
ensure_utc_rtc
# Dead since it was written: usbcore is built into the kernel, so modprobe never read this file.
ensure_root_file_absent /etc/modprobe.d/vekrona-usb-autosuspend.conf

if grep -qE '^[[:space:]]*deny[[:space:]]*=' /etc/security/faillock.conf 2>/dev/null; then
  assert_file_contains /etc/security/faillock.conf '^[[:space:]]*deny[[:space:]]*=[[:space:]]*10[[:space:]]*$'
else
  ensure_line /etc/security/faillock.conf "deny = 10"
fi

# The xremap user is the only one that reads the keyboards: the session user must not (any program it runs could log every
# key). Where the group was added by an earlier install, it is taken away again.
ensure_user_not_in_group input

ensure_pkg acl
ensure_root_file "$VEKRONA_ROOT/etc/sysusers.d/vekrona-xremap.conf" /etc/sysusers.d/vekrona-xremap.conf
root systemd-sysusers /etc/sysusers.d/vekrona-xremap.conf
user_in_group xremap input || die "the xremap user is not in the input group after systemd-sysusers"
ensure_root_file "$VEKRONA_ROOT/etc/modules-load.d/vekrona-uinput.conf" /etc/modules-load.d/vekrona-uinput.conf
root modprobe uinput
assert "uinput module loaded" grep -q '^uinput ' /proc/modules
assert "xremap udev rule installed" test -f /usr/lib/udev/rules.d/00-xremap-input.rules
ensure_root_file "$VEKRONA_ROOT/etc/udev/rules.d/70-vekrona-uinput.rules" /etc/udev/rules.d/70-vekrona-uinput.rules

ensure_root_file_absent /etc/udev/rules.d/70-vekrona-dgpu.rules
root udevadm control --reload
root udevadm trigger --settle --sysname-match=uinput
# The seat ACL that 00-xremap-input.rules' uaccess tag gave /dev/uinput stays until it is removed by hand.
root setfacl -b /dev/uinput

# xremap runs as a system service of its own (the user systemd service it was is stopped); it starts when a Wayland
# socket appears. Its config is root's copy: a file the user can write would run commands (launch:) as the xremap user.
ensure_user_unit_stopped xremap.service
ensure_system_unit_file "$VEKRONA_ROOT/etc/systemd/system/xremap.service"
with_scratch_dir install_xremap_path_unit
ensure_dropins_restarting xremap.service "$VEKRONA_ROOT/config/xremap" /etc/xremap config.yml
ensure_system_unit --now enabled xremap.path

# These only reload systemd: restarting NetworkManager would drop the network mid-install, and the ordering matters at shutdown.
for dropin in NetworkManager.service.d/vekrona-shutdown-order.conf NetworkManager-dispatcher.service.d/vekrona-persist.conf; do
  ensure_root_file "$VEKRONA_ROOT/etc/systemd/system/$dropin" "/etc/systemd/system/$dropin"
done
root systemctl daemon-reload

ensure_system_unit enabled tailscaled nix-daemon.service
ensure_system_unit_active tailscaled nix-daemon.service

# Before the operator step, which dies on a logged-out node: ssh restrictions do not depend on a Tailscale login.
# ensure_tailnet_ssh_only needs the tailscale0 interface, which tailscaled has created by now.
ensure_default_zone
ensure_sshd_keys_only
ensure_tailnet_ssh_only
ensure_airplay_ports
if firewalld_active; then
  high_port_zones="$(zones_open_to_high_ports)"
  [[ -z "$high_port_zones" ]] || report_failure "the zones $(tr '\n' ' ' <<<"$high_port_zones")open every TCP and UDP port from 1025 to this network and have interfaces: a NetworkManager connection sets its zone (nmcli connection modify <connection> connection.zone '')"
fi

tailscale_operator() { root tailscale debug prefs | jq -r '.OperatorUser // ""'; }

ensure_tailscale_operator() {
  local user="$1"
  [[ "$(tailscale_operator)" == "$user" ]] && { log "tailscale operator: $user"; return 0; }
  log "setting tailscale operator: $user"
  root tailscale set --operator="$user"
  [[ "$(tailscale_operator)" == "$user" ]] || die "tailscale operator not set to $user: run 'tailscale up' to log in, then re-run ./install.sh 40"
}

ensure_tailscale_operator "$VEKRONA_USER"
