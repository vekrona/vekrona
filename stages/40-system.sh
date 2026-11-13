#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../lib/firewall.sh
source "$ROOT/lib/firewall.sh"
# shellcheck source=../lib/tailscale.sh
source "$ROOT/lib/tailscale.sh"
# shellcheck source=../lib/tor.sh
source "$ROOT/lib/tor.sh"
# shellcheck source=../lib/geoclue.sh
source "$ROOT/lib/geoclue.sh"
# shellcheck source=../lib/vpn.sh
source "$ROOT/lib/vpn.sh"
# shellcheck source=../lib/xremap.sh
source "$ROOT/lib/xremap.sh"

ensure_system_copy
root "$VEKRONA_SYSTEM_DIR/libexec/vekrona-update-seed"

mapfile -t shipped_units < <(shipped_system_unit_files)
for unit in "${shipped_units[@]}"; do
  ensure_system_unit_file "$unit"
done
# The kill switch unit is gone: vekrona-vpn-apply loads and removes the nft table itself. An armed table stays until "vekrona-vpn off",
# except the one an earlier install's unit loaded, which nothing else would remove.
retire_vpn_killswitch_unit
for rule in "$VEKRONA_ROOT"/etc/polkit-1/rules.d/50-vekrona-*.rules; do
  ensure_root_file "$rule" "/etc/polkit-1/rules.d/${rule##*/}"
done
# The state file of vekrona-vpn exists from boot (and now: tmpfiles only creates what is missing, an arm's file stays).
ensure_root_file "$VEKRONA_ROOT/etc/tmpfiles.d/vekrona-vpn.conf" /etc/tmpfiles.d/vekrona-vpn.conf
root systemd-tmpfiles --create /etc/tmpfiles.d/vekrona-vpn.conf
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
# zram-generator sets the device up at boot: a running zram0 keeps its algorithm until the next boot.
ensure_root_file "$VEKRONA_ROOT/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
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

# xremap runs as a system service of its own; it starts when a Wayland socket appears. The user unit it was is stopped first, since
# two xremaps would grab the keyboards, and stage 50 retires its links (VEKRONA_RETIRED_USER_UNITS). Its config is root's copy: a file the user can write would run commands (launch:) as the xremap user.
ensure_user_unit_stopped xremap.service
ensure_system_unit_file "$VEKRONA_ROOT/etc/systemd/system/xremap.service"
with_scratch_dir install_xremap_path_unit
ensure_dropins_restarting xremap.service "$VEKRONA_ROOT/config/xremap" /etc/xremap config.yml
ensure_system_unit --now enabled xremap.path

# tor serves Tor Browser, whose Flatpak has no network of its own and reaches tor through a socket in /run/vekrona-tor (group
# vekrona-tor, which the session user joins: a new login applies it). vekrona-tor-browser starts tor with the browser and
# stops it after, so tor is not enabled at boot. tor_t may create that socket only in a directory labelled tor_var_run_t,
# and a tmpfiles.d entry for the directory would land in the initramfs, which has no toranon user: libexec/vekrona-tor-prepare
# makes it when tor starts. The drop-in restarts a running tor; the route unit keeps tor out of the VPN.
ensure_root_file "$VEKRONA_ROOT/etc/sysusers.d/vekrona-tor.conf" /etc/sysusers.d/vekrona-tor.conf
root systemd-sysusers /etc/sysusers.d/vekrona-tor.conf
ensure_user_in_group "$VEKRONA_TOR_GROUP"
# /run/tor-tb was the socket directory before it was renamed to $VEKRONA_TOR_SOCKET_DIR; an earlier install left its rule behind.
ensure_fcontext_dropped "/run/tor-tb(/.*)?"
# An earlier install left the old socket directory behind, and nothing else removes it.
[[ ! -d /run/tor-tb ]] || root rm -rf -- /run/tor-tb
ensure_fcontext tor_var_run_t "$VEKRONA_TOR_SOCKET_DIR(/.*)?"
ensure_system_unit_file "$VEKRONA_ROOT/etc/systemd/system/vekrona-tor-route.service"
ensure_dropins_restarting tor.service "$VEKRONA_ROOT/etc/tor/torrc.d" /etc/tor/torrc.d vekrona.conf
ensure_dropins_restarting tor.service "$VEKRONA_ROOT/etc/systemd/system/tor.service.d" /etc/systemd/system/tor.service.d vekrona.conf
ensure_system_unit disabled tor.service

# These only reload systemd, except the dispatcher: restarting NetworkManager would drop the network mid-install, and the
# ordering matters at shutdown; tailscaled gets shields up and ssh off by ensure_tailscale_settings below, and again by the
# drop-in at its next start. The dispatcher is idle between network events, so it restarts at once without --persist.
for dropin in NetworkManager.service.d/vekrona-shutdown-order.conf tailscaled.service.d/vekrona-hardening.conf; do
  ensure_root_file "$VEKRONA_ROOT/etc/systemd/system/$dropin" "/etc/systemd/system/$dropin"
done
ensure_nm_dispatcher_not_persistent

ensure_system_unit enabled tailscaled
ensure_system_unit_active tailscaled

# Before the tailscale step, which dies on a logged-out node: the firewall does not depend on a Tailscale login.
ensure_root_file_absent /etc/ssh/sshd_config.d/10-vekrona.conf # no RPM owns it, so it outlives openssh-server
ensure_system_unit enabled firewalld
ensure_system_unit_active firewalld
ensure_tailnet_ssh_firewall_gone
mapfile -t zone_services < <(default_zone_services)
ensure_default_zone "${zone_services[@]}"
high_port_zones="$(zones_open_to_high_ports)"
[[ -z "$high_port_zones" ]] || report_failure "the zones $(tr '\n' ' ' <<<"$high_port_zones")open every TCP port from $HIGH_PORTS_FIRST to this network and have interfaces: a NetworkManager connection sets its zone (nmcli connection modify <connection> connection.zone '')"
accepting_zones="$(zones_accepting_everything)"
[[ -z "$accepting_zones" ]] || report_failure "the zones $(tr '\n' ' ' <<<"$accepting_zones")accept every connection and have interfaces: a NetworkManager connection sets its zone (nmcli connection modify <connection> connection.zone ''), or a program such as libvirt or Docker made it"

# Modules nothing here uses stay unloadable; the sysctl file holds vekrona's kernel sysctls (hardening and swap), read after Fedora's own.
ensure_root_file "$VEKRONA_ROOT/etc/modprobe.d/vekrona-hardening.conf" /etc/modprobe.d/vekrona-hardening.conf
ensure_dropins_restarting systemd-sysctl.service "$VEKRONA_ROOT/etc/sysctl.d" /etc/sysctl.d 60-vekrona.conf

# LLMNR and mDNS answer to the local network and are not used (avahi is removed by stage 30).
ensure_dropins_restarting systemd-resolved "$VEKRONA_ROOT/etc/systemd/resolved.conf.d" /etc/systemd/resolved.conf.d 50-vekrona.conf

ensure_tailscale_settings "$VEKRONA_USER"
