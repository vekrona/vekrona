#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/authselect-vekrona.sh"
source "$ROOT/lib/pam-u2f.sh"
source "$ROOT/lib/yubikey-otp.sh"
source "$ROOT/lib/luks-fido2.sh"
source "$ROOT/lib/facetimehd.sh"
source "$ROOT/lib/proton.sh"
source "$ROOT/lib/firewall.sh"
source "$ROOT/lib/tailnet-ssh.sh"
source "$ROOT/lib/cuda-repo.sh"
source "$ROOT/lib/geoclue.sh"
source "$ROOT/lib/xremap.sh"
source "$ROOT/lib/display-scale.sh"

[[ "${1:-}" == "--all" ]] && VEKRONA_VERIFY_ALL=1
VEKRONA_VERIFY_ALL="${VEKRONA_VERIFY_ALL:-0}"
VEKRONA_STAGES="${VEKRONA_STAGES:-}"

ran() {
  if [[ "$VEKRONA_VERIFY_ALL" == "1" ]]; then
    stage_applies "$1"
  else
    [[ " $VEKRONA_STAGES " == *" $1 "* ]]
  fi
}

ok_count=0
warn_count=0

check() { "$@"; ok_count=$((ok_count + 1)); }

warn_check() {
  local msg="$1"; shift
  if "$@"; then
    log "ok: $msg"
    ok_count=$((ok_count + 1))
  else
    warn "$msg"
    warn_count=$((warn_count + 1))
  fi
}

eq() { [[ "$1" == "$2" ]]; }
ge() { [[ "$1" -ge "$2" ]]; }
contains() { [[ "$2" == *"$1"* ]]; }
not_contains() { [[ "$2" != *"$1"* ]]; }
file_exists() { [[ -e "$1" ]]; }
fprintd_sees_reader() { fprintd-list "$VEKRONA_USER" >/dev/null 2>&1; }
dir_exists() { [[ -d "$1" ]]; }
gsettings_eq() { [[ "$(user_gsettings get "$1" "$2")" == "'$3'" ]]; }
# stat -L: the rpmfusion-*-release packages ship their per-release key as a symlink to the -2020 key, which is the file that counts.
repo_key_target_root_0644() { [[ "$(stat -L -c '%U %a' "$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$1")")" == "root 644" ]]; }
not_repo_enabled() { ! repo_enabled "$1"; }
copr_enabled() { repo_enabled "$(copr_id "$1")"; }
unit_enabled() { eq "$(systemctl is-enabled "$1" 2>/dev/null || true)" enabled; }
unit_active() { eq "$(systemctl is-active "$1" 2>/dev/null || true)" active; }
user_unit_enabled() { eq "$(systemctl --user is-enabled "$1" 2>/dev/null || true)" enabled; }
user_unit_loaded() { eq "$(systemctl --user show -p LoadState --value "$1" 2>/dev/null || true)" loaded; }
# rpm -q exits 1 for an absent package and for a broken rpm database alike, so only its "is not installed" answer counts.
pkg_absent() { [[ "$(LC_ALL=C rpm -q "$1" 2>&1 || true)" == "package $1 is not installed" ]]; }
gdm_absent_or_disabled() { ! pkg_installed gdm || ! unit_enabled gdm; }
# The package owns at least one .desktop file under /usr/share/applications, and every one of them is on disk.
pkg_desktop_files_present() {
  local files file
  files="$(rpm -ql "$1" | grep '^/usr/share/applications/.*\.desktop$')" || return 1
  while IFS= read -r file; do [[ -f "$file" ]] || return 1; done <<<"$files"
}
file_executable() { [[ -x "$1" ]]; }
logind_idle_action() { [[ "$(loginctl show-session -p IdleAction --value)" == suspend ]]; }
# logind arms its idle timer only when it starts, so IdleAction is live only for a logind that started after the drop-in.
logind_started_after_idle_dropin() {
  local started
  started="$(date -d "$(systemctl show systemd-logind -p ActiveEnterTimestamp --value)" +%s)"
  (( started >= $(stat -c %Y /etc/systemd/logind.conf.d/vekrona-idle.conf) ))
}
mem_sleep_offers_deep() { grep -qw deep /sys/power/mem_sleep; }
module_loaded() { [[ -d "/sys/module/$1" ]]; }
module_built_for_running_kernel() { modinfo -k "$(uname -r)" "$1" >/dev/null 2>&1; }
nvidia_module_present_for() { modinfo -k "$1" nvidia >/dev/null 2>&1; }
root_files_equal() { root cmp -s "$1" "$2"; }
user_has_touch_credentials() { root test -e "$U2F_MAPPINGS" || root test -e "/var/lib/fprint/$VEKRONA_USER"; }
vekrona_pam_u2f_lines_ok() {
  local content pinned total
  content="$(<"$1")"
  pinned="$(count_occurrences "$content" "$PAM_U2F_VEKRONA")"
  total="$(count_occurrences "$content" "pam_u2f.so")"
  [[ "$pinned" -eq "$2" && "$total" -eq "$2" ]]
}
# An inactive irqbalance (ConditionCPUs=>1 on a single CPU, or a container) has no command line to check.
uinput_has_user_acl() { root getfacl -cp /dev/uinput | awk '/^user:[^:]/ { found = 1 } END { exit !found }'; }
irqbalance_bans_nvme_when_running() {
  local pid
  pid="$(systemctl show irqbalance -p MainPID --value)"
  [[ "$pid" -eq 0 ]] || tr '\0' ' ' <"/proc/$pid/cmdline" | grep -qF -- '--banmod=nvme'
}
tailscale_prefs() { root tailscale debug prefs; }
tailscale_logged_out() { [[ "$(tailscale_prefs | jq -r '.LoggedOut')" == true ]]; }
tailscale_operator_is_user() { [[ "$(tailscale_prefs | jq -r '.OperatorUser // ""')" == "$VEKRONA_USER" ]]; }
authselect_selection_ok() {
  local want have
  want="$(printf '%s\n' custom/vekrona with-silent-lastlog with-fingerprint with-mdns4 with-pam-u2f | sort | paste -sd' ')"
  have="$(authselect current --raw | tr ' ' '\n' | sed '/^$/d' | sort | paste -sd' ')"
  [[ "$have" == "$want" ]]
}
not() { if "$@"; then return 1; fi; }
present_iff() {
  local applicable="$1"; shift
  if "$applicable"; then "$@"; else not "$@"; fi
}

sway_runs() { [[ -n "$(sway_socket)" ]]; }
system_unit_active_when_sway_runs() { ! sway_runs || unit_active "$1"; }
active_when_sway_runs() { ! sway_runs || systemctl --user is-active --quiet "$1"; }
runs_when_sway_runs() { ! sway_runs || systemctl --user start "$1"; }
session_teardown_holds_shutdown_lock() {
  systemd-inhibit --list --no-legend --no-pager | awk '$1 == "vekrona" && $NF == "delay" { for (i = 2; i < NF; i++) if ($i == "shutdown") found = 1 } END { exit !found }'
}
user_unit_active_without_restarts() {
  local props
  props="$(systemctl --user show -p ActiveState,NRestarts "$1")"
  grep -qx 'ActiveState=active' <<<"$props" && grep -qx 'NRestarts=0' <<<"$props"
}

verify_greetd_enabled() {
  check assert "greetd enabled" greetd_enabled
  check assert "display-manager.service points to greetd" dm_is_greetd
  check assert "default target is graphical.target" default_target_is_graphical
}

if ran 00-repos; then
  check assert "repo enabled: rpmfusion-nonfree" repo_enabled rpmfusion-nonfree
  for section in free nonfree; do
    check assert "rpmfusion-$section.repo takes its key only from the pinned key file" rpmfusion_repo_file_uses_pinned_key "$section"
  done
  check assert "repo enabled: fedora-cisco-openh264" repo_enabled fedora-cisco-openh264
  check assert "repo enabled: 1password" repo_enabled 1password
  check assert "/etc/yum.repos.d/1password.repo matches repo" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" /etc/yum.repos.d/1password.repo
  check assert "repo enabled: protonvpn-fedora-stable" repo_enabled protonvpn-fedora-stable
  check assert "/etc/yum.repos.d/protonvpn-stable.repo matches repo" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/protonvpn-stable.repo" /etc/yum.repos.d/protonvpn-stable.repo
  for pin in "${!VEKRONA_REPO_KEY_FINGERPRINTS[@]}"; do
    [[ "$pin" != "$CUDA_KEY_REPO" ]] || continue # installed by stage 10, on NVIDIA machines only
    check assert_repo_key_trusted "$pin"
    check assert "$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$pin") is root-owned 0644" repo_key_target_root_0644 "$pin"
  done
  # A pin kept for a Fedora release the system has left would silently stop covering the repo files, which read $releasever.
  fedora_release="$(rpm -E %fedora)"
  for pin in "${!VEKRONA_REPO_KEY_FINGERPRINTS[@]}"; do
    [[ "$pin" != "$CUDA_KEY_REPO" ]] || continue
    [[ "$pin" =~ -fedora-([0-9]+)$ ]] || continue
    warn_check "pinned per-release key $pin is for the running Fedora $fedora_release" eq "${BASH_REMATCH[1]}" "$fedora_release"
  done
  for c in "${VEKRONA_COPRS[@]}"; do
    check assert "copr enabled: $c" copr_enabled "$c"
    copr_repo_file="$(copr_key_repo "$c").repo"
    check assert "/etc/yum.repos.d/$copr_repo_file matches the checkout (pinned key, includepkgs)" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/$copr_repo_file" "/etc/yum.repos.d/$copr_repo_file"
    check assert "no unpinned dnf-copr repo file for $c is left" path_absent "/etc/yum.repos.d/_$(copr_id "$c").repo"
  done
fi

if ran 10-nvidia; then
  check assert "akmod-nvidia installed" pkg_installed akmod-nvidia
  check assert "libva-nvidia-driver installed" pkg_installed libva-nvidia-driver

  nvidia_pending="$(nvidia_reboot_reason)"
  if [[ -z "$nvidia_pending" ]]; then
    modeset="$(root cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo '?')"
    check assert "nvidia_drm modeset=Y" eq "$modeset" Y
    gsp="$(nvidia-smi -q 2>/dev/null | grep 'GSP Firmware' || true)"
    check assert "GSP firmware disabled (N/A)" contains 'N/A' "$gsp"
    check assert "nvidia module is proprietary, not Open" not_contains 'Open' "$(cat /proc/driver/nvidia/version 2>/dev/null || true)"
  else
    warn_check "nvidia_drm modeset=Y (reboot pending: $nvidia_pending)" false
    warn_check "GSP firmware disabled (N/A) (reboot pending)" false
    warn_check "nvidia module is proprietary, not Open (reboot pending)" false
  fi

  mapfile -t nvidia_args < <(nvidia_kernel_args)
  for arg in "${nvidia_args[@]}"; do
    state="$(kernel_arg_state "$arg")"
    case "$state" in
      active)
        log "ok: kernel arg active: $arg"
        ok_count=$((ok_count + 1)) ;;
      pending)
        warn "kernel arg configured but not active yet, reboot required: $arg"
        warn_count=$((warn_count + 1)) ;;
      missing) die "kernel arg not configured: $arg" ;;
    esac
  done

  check assert "nvidia module for kernel $(uname -r) is proprietary (license NVIDIA)" eq "$(nvidia_module_problem "$(uname -r)")" ""
  check assert "initramfs for kernel $(uname -r) contains nvidia" initramfs_has_nvidia "$(uname -r)"
  check assert "initramfs for kernel $(uname -r) carries $NVIDIA_MODPROBE_CONF" initramfs_has_nvidia_options "$(uname -r)"
  if [[ -e /proc/driver/nvidia/params ]]; then
    warn_check "nvidia runs with NVreg_UseKernelSuspendNotifiers=0 (reboot pending)" nvidia_suspend_notifiers_off
  fi
  check assert "akmods@$(uname -r) runs vekrona-kernel-ready (initramfs, then GRUB default) after its build" akmods_dropin_active "akmods@$(uname -r).service"
  check assert "akmods.service regenerates the initramfs after its boot-time build" akmods_dropin_active akmods.service
  check assert "the script of the akmods.service drop-in exists in the root-owned copy" test -x "$VEKRONA_SYSTEM_DIR/libexec/vekrona-nvidia-initramfs"
  check assert "$SYSCONFIG_KERNEL has UPDATEDEFAULT=no, so a new kernel is not the GRUB default before it has nvidia" kernel_updatedefault_is_no
  check assert "the GRUB default boot entry (saved_entry) exists, so installonly pruning did not leave it dangling" default_boot_entry_exists
  check assert "the GRUB default kernel's initramfs contains nvidia" default_kernel_initramfs_has_nvidia

  for u in nvidia-suspend nvidia-resume nvidia-hibernate; do
    check assert "$u enabled" unit_enabled "$u"
  done

  is_laptop || check assert "nvidia-powerd (Dynamic Boost, laptops only) not enabled on a desktop" not unit_enabled nvidia-powerd.service
  check assert "versionlock: akmod-nvidia" versionlock_has akmod-nvidia

  for d in /lib/modules/*/; do
    kver="$(basename "$d")"
    [[ -e "/boot/vmlinuz-$kver" ]] || continue
    warn_check "nvidia module present for kernel $kver" nvidia_module_present_for "$kver"
  done

  check assert_repo_key_trusted "$CUDA_KEY_REPO"
  check assert "$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$CUDA_KEY_REPO") is root-owned 0644" repo_key_target_root_0644 "$CUDA_KEY_REPO"
  check assert "$CUDA_REPO_ID enabled" repo_enabled "$CUDA_REPO_ID"
  check assert "/etc/yum.repos.d/$CUDA_REPO_FILE_NAME matches the checkout (pinned key, includepkgs)" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/$CUDA_REPO_FILE_NAME" "/etc/yum.repos.d/$CUDA_REPO_FILE_NAME"
  check assert "$CUDA_REPO_ID has no excludepkgs override left from the denylist days" not repo_override_has "$CUDA_REPO_ID" excludepkgs
  check assert "the stale CUDA repo file $CUDA_STALE_REPO_FILE is absent" path_absent "$CUDA_STALE_REPO_FILE"
fi

if ran 20-snapper; then
  check assert "snapper config: NUMBER_LIMIT=10" root grep -qE '^NUMBER_LIMIT="10"$' /etc/snapper/configs/root
  check assert "snapper config: TIMELINE_CREATE=no" root grep -qE '^TIMELINE_CREATE="no"$' /etc/snapper/configs/root
  check assert "libdnf5-plugin-actions installed" pkg_installed libdnf5-plugin-actions
  check assert "snapper-cleanup.timer enabled" unit_enabled snapper-cleanup.timer

  # Read-only: an install and a removal here would take two snapshots and push the oldest rollback point out of NUMBER_LIMIT.
  check assert "snapper lists the snapshots of /" root snapper -c root --csvout --no-headers list --columns number
  check assert "the dnf snapshot script is in the root-owned copy" file_executable "$VEKRONA_SYSTEM_DIR/libexec/vekrona-snapper-snapshot"
  check assert "the snapper actions file runs that script before and after each transaction" root_files_equal "$VEKRONA_ROOT/etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions" /etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions

  nix_mounted_from_subvol() { [[ "$(findmnt -no SOURCE /nix 2>/dev/null)" == *"[/nix]" ]]; }
  check assert "/nix mounted from subvolume nix" nix_mounted_from_subvol

  nix_fstab_line="$(fstab_line_for_mountpoint /nix)" || die "no fstab entry for /nix"
  home_fstab_line="$(fstab_line_for_mountpoint /home)" || die "no fstab entry for /home"
  read -r nix_device _ _ nix_options _ _ <<<"$nix_fstab_line"
  read -r home_device _ <<<"$home_fstab_line"
  check assert "fstab /nix options contain subvol=nix" contains "subvol=nix" "$nix_options"
  check assert "fstab /nix device matches /home device" eq "$nix_device" "$home_device"

  check assert "/nix migration marker present" file_exists /nix/.vekrona-migrated
  check assert "/nix.pre-vekrona backup absent" path_absent /nix.pre-vekrona
fi

if ran 30-packages; then
  declare -a versionlock_pkgs
  read_pkg_list versionlock_pkgs vekrona_versionlock_pkgs
  for p in "${versionlock_pkgs[@]}" ghostty greetd tuigreet; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  quickshell_vendor="$(rpm -q --qf '%{VENDOR}' quickshell 2>/dev/null || true)"
  check assert "quickshell vendor is not agaspar" not_contains agaspar "$quickshell_vendor"
  for p in "${versionlock_pkgs[@]}"; do
    check assert "versionlock: $p" versionlock_has "$p"
  done
  os_version_id="$(source /etc/os-release && echo "$VERSION_ID")"
  while IFS= read -r entry; do
    [[ "$entry" =~ \.fc([0-9]+) ]] || continue
    fcver="${BASH_REMATCH[1]}"
    warn_check "versionlock entry matches fc$os_version_id: $entry" eq "$fcver" "$os_version_id"
  done < <(versionlock_evrs)
  check assert "greetd user exists" bash -c "getent passwd greetd >/dev/null"
  # The proton-vpn-daemon RPM enables and starts its split-tunneling service itself.
  check assert "me.proton.vpn.split_tunneling.service enabled" unit_enabled me.proton.vpn.split_tunneling
  check assert "me.proton.vpn.split_tunneling.service active" unit_active me.proton.vpn.split_tunneling

  check assert "/etc/yum.repos.d/vekrona-proton.repo matches repo" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/vekrona-proton.repo" /etc/yum.repos.d/vekrona-proton.repo
  check assert "repo enabled: vekrona-proton" repo_enabled vekrona-proton
  for p in $(proton_package_names); do
    check assert "package installed: $p" pkg_installed "$p"
    check assert "$p ships its .desktop file" pkg_desktop_files_present "$p"
  done

  check assert "package installed: tuned-ppd" pkg_installed tuned-ppd
  for p in "${VEKRONA_RETIRED_PKGS[@]}"; do
    check assert "rpm -q $p finds nothing (retired)" pkg_absent "$p"
  done
  check assert "command -v dms fails" bash -c "! command -v dms"
  check assert "versionlock has no dms" not versionlock_has dms
  check assert "repo not enabled: $VEKRONA_RETIRED_MISE_REPO_ID (retired)" not_repo_enabled "$VEKRONA_RETIRED_MISE_REPO_ID"
  check assert "rpm keyring lacks the retired mise key" not gpg_pubkey_installed "$(tr '[:upper:]' '[:lower:]' <<<"$VEKRONA_RETIRED_MISE_KEY_FPR")"
  for leftover in "${VEKRONA_RETIRED_AGENT_FILES[@]}" "${VEKRONA_RETIRED_AGENT_TREES[@]}"; do
    check assert "retired agent file or tree absent: $leftover" path_absent "$leftover"
  done
  for link in "${VEKRONA_RETIRED_AGENT_LINKS[@]}"; do
    check assert "$link is absent or not a symlink into the retired mise share" not links_into_retired_mise_share "$link"
  done
  check assert "tuned.service enabled" unit_enabled tuned
  check assert "tuned-ppd.service enabled" unit_enabled tuned-ppd
  warn_check "power profiles D-Bus name answers: net.hadess.PowerProfiles" \
    busctl introspect net.hadess.PowerProfiles /net/hadess/PowerProfiles

  check assert "flathub flatpak remote present and enabled system-wide" flatpak_remote_system_enabled flathub
  for app_id in "${VEKRONA_FLATPAKS[@]}"; do
    check assert "$app_id flatpak installed" flatpak_installed "$app_id"
  done

  declare -a desktop_pkgs
  read_pkg_list desktop_pkgs vekrona_desktop_pkgs
  for p in "${desktop_pkgs[@]}"; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "package absent: ffmpeg-free" pkg_absent ffmpeg-free

  for p in "${!VEKRONA_PINNED_PKGS[@]}"; do
    check assert "package installed from pinned repo: $p" eq "$(installed_from_repo "$p")" "${VEKRONA_PINNED_PKGS[$p]}"
  done

  for stale in "$HOME/.local/zed.app" "$HOME/.local/bin/zed" "$HOME/.local/share/applications/dev.zed.Zed.desktop"; do
    check assert "no stale tarball Zed at $stale (if present, remove it: it shadows the dev.zed.Zed Flatpak)" \
      path_absent "$stale"
  done
fi

if ran 40-system; then
  check assert "$VEKRONA_SYSTEM_DIR/lib matches the checkout's lib/" root_tree_matches "$VEKRONA_ROOT/lib" "$VEKRONA_SYSTEM_DIR/lib"
  check assert "$VEKRONA_SYSTEM_DIR/libexec matches the checkout's libexec/" root_tree_matches "$VEKRONA_ROOT/libexec" "$VEKRONA_SYSTEM_DIR/libexec"
  check assert "/var/lib/vekrona/updates.json exists, so the shell can watch it" file_exists /var/lib/vekrona/updates.json
  for script in "${VEKRONA_SYSTEM_BIN[@]}"; do
    check assert "$VEKRONA_SYSTEM_DIR/bin/$script matches the checkout's bin/$script" root_files_equal "$VEKRONA_ROOT/bin/$script" "$VEKRONA_SYSTEM_DIR/bin/$script"
  done
  check assert "$VEKRONA_SYSTEM_DIR/etc/yum.repos.d/1password.repo matches the repo file" root_files_equal "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" "$VEKRONA_SYSTEM_DIR/etc/yum.repos.d/1password.repo"
  for unit_file in "$VEKRONA_ROOT"/etc/systemd/system/vekrona-update-*; do
    check assert "/etc/systemd/system/${unit_file##*/} matches the checkout" root_files_equal "$unit_file" "/etc/systemd/system/${unit_file##*/}"
  done
  check assert "/etc/claude-code/managed-settings.json matches the repo file" root_files_equal "$VEKRONA_ROOT/etc/claude-code/managed-settings.json" /etc/claude-code/managed-settings.json
  check assert "/etc/claude-code/managed-settings.json is root:root 0644, so no user can loosen the policy" eq "$(root stat -c '%U:%G %a' /etc/claude-code/managed-settings.json)" "root:root 644"
  for rule in "$VEKRONA_ROOT"/etc/polkit-1/rules.d/50-vekrona-*.rules; do
    check assert "polkit rule ${rule##*/} matches the checkout" root_files_equal "$rule" "/etc/polkit-1/rules.d/${rule##*/}"
  done
  check assert "vekrona-update-check.timer enabled" unit_enabled vekrona-update-check.timer
  check assert "vekrona-update-check.timer active" unit_active vekrona-update-check.timer
  check assert "vekrona-update-post.service enabled" unit_enabled vekrona-update-post.service
  check assert_file_contains /etc/greetd/config.toml 'user = "greetd"'
  check assert "greetd creates /var/cache/tuigreet on start" file_exists /etc/systemd/system/greetd.service.d/vekrona-tuigreet-cache.conf
  check assert "no tmpfiles.d entry for greetd's cache dir (dracut copies it into an initramfs without the user)" path_absent /etc/tmpfiles.d/vekrona-tuigreet.conf
  check assert "/var/cache/tuigreet exists" dir_exists /var/cache/tuigreet
  check assert "/var/cache/tuigreet owned by greetd" owned_by /var/cache/tuigreet greetd
  check assert "default error mutes installed" file_exists /etc/vekrona/errors-mute.d/10-vendor-noise.conf
  check assert "logind inhibit-delay drop-in present" file_exists /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf
  check assert "logind idle drop-in present" file_exists /etc/systemd/logind.conf.d/vekrona-idle.conf
  check assert "running logind has IdleAction=suspend" logind_idle_action
  check assert "logind started after its idle drop-in, so its idle timer is armed" logind_started_after_idle_dropin
  check assert "sleep drop-in present" file_exists /etc/systemd/sleep.conf.d/vekrona.conf
  warn_check "hardware offers deep suspend (/sys/power/mem_sleep lists deep); otherwise suspend falls back to s2idle" mem_sleep_offers_deep
  check assert "oomd drop-in present" file_exists /etc/systemd/oomd.conf.d/vekrona.conf
  check assert "coredump retention drop-in present" file_exists /etc/systemd/coredump.conf.d/50-vekrona.conf
  if irqbalance_wanted; then
    check assert "irqbalance bans the nvme driver (sysconfig matches the checkout)" root_files_equal "$VEKRONA_ROOT/etc/sysconfig/irqbalance" /etc/sysconfig/irqbalance
    check assert "irqbalance drop-in matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/systemd/system/irqbalance.service.d/vekrona.conf" /etc/systemd/system/irqbalance.service.d/vekrona.conf
    check assert "irqbalance runs without a private network, so it can reach the thermal netlink family" eq "$(systemctl show irqbalance -p PrivateNetwork --value)" no
    check assert "a running irqbalance was started with --banmod=nvme" irqbalance_bans_nvme_when_running
  else
    check assert "irqbalance is disabled on a laptop" not unit_enabled irqbalance.service
    check assert "irqbalance is not running on a laptop" not unit_active irqbalance.service
  fi
  check assert "sudo's PAM service vekrona-sudo matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/pam.d/vekrona-sudo" /etc/pam.d/vekrona-sudo
  check assert "sudo's PAM environment file matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/vekrona/sudo-session.env" /etc/vekrona/sudo-session.env
  check assert "sudoers drop-in 50-vekrona-sudo-pam-service matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/sudoers.d/50-vekrona-sudo-pam-service" /etc/sudoers.d/50-vekrona-sudo-pam-service
  check assert "sudoers drop-in is root:root 0440" eq "$(root stat -c '%U:%G %a' /etc/sudoers.d/50-vekrona-sudo-pam-service)" "root:root 440"
  check assert "the earlier global 'Defaults !pam_session' drop-in is gone" path_absent /etc/sudoers.d/50-vekrona-no-pam-session
  check assert "sudo configuration parses (visudo -c)" root visudo -c
  geoclue_want="$(render_geoclue_conf "$(id -u)" <"$VEKRONA_ROOT/etc/geoclue/conf.d/90-vekrona.conf")"
  geoclue_have="$(root cat /etc/geoclue/conf.d/90-vekrona.conf)"
  check assert "geoclue lists the uid of $VEKRONA_USER and nobody else" eq "$geoclue_want" "$geoclue_have"
  check assert "Firefox's policies.json matches the checkout" root_files_equal "$VEKRONA_ROOT/config/firefox/policies.json" /usr/lib64/firefox/distribution/policies.json
  check assert "syncthing GUI requires a login" syncthing_gui_user_set
  for dropin in NetworkManager.service.d/vekrona-shutdown-order.conf NetworkManager-dispatcher.service.d/vekrona-persist.conf; do
    check assert "/etc/systemd/system/$dropin matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/systemd/system/$dropin" "/etc/systemd/system/$dropin"
  done
  check assert "NetworkManager stops before nm-dispatcher and wpa_supplicant" contains NetworkManager-dispatcher.service "$(systemctl show NetworkManager -p After --value)"
  check assert "nm-dispatcher runs with --persist" contains "nm-dispatcher --persist" "$(systemctl show NetworkManager-dispatcher -p ExecStart --value)"
  check assert "hardware clock holds UTC" rtc_is_utc
  check assert "no dead usbcore modprobe drop-in from an earlier install" path_absent /etc/modprobe.d/vekrona-usb-autosuspend.conf
  check assert "no stale dGPU udev rule from an earlier install" path_absent /etc/udev/rules.d/70-vekrona-dgpu.rules
  warn_check "no dead /dev/dri/vekrona-dgpu node from the old udev rule (reboot pending)" path_absent /dev/dri/vekrona-dgpu
  check assert "$VEKRONA_USER is not in the input group (no process of the session can read raw key events)" not user_in_group "$VEKRONA_USER" input
  check assert "the xremap user is in the input group" user_in_group xremap input
  check assert "/dev/uinput exists" file_exists /dev/uinput
  check assert "/dev/uinput is root:input 0660" eq "$(root stat -c '%U:%G %a' /dev/uinput)" "root:input 660"
  check assert "no user has an ACL on /dev/uinput (the seat's uaccess tag would let its programs inject key presses)" not uinput_has_user_acl
  for file in etc/udev/rules.d/70-vekrona-uinput.rules etc/sysusers.d/vekrona-xremap.conf etc/systemd/system/xremap.service; do
    check assert "/$file matches the checkout" root_files_equal "$VEKRONA_ROOT/$file" "/$file"
  done
  xremap_path_want="$(render_xremap_path_unit "$(id -u)" <"$VEKRONA_ROOT/etc/systemd/system/xremap.path")"
  xremap_path_have="$(root cat /etc/systemd/system/xremap.path)"
  check assert "xremap.path watches the runtime directory of $VEKRONA_USER" eq "$xremap_path_want" "$xremap_path_have"
  check assert "/etc/xremap/config.yml matches the checkout" root_files_equal "$VEKRONA_ROOT/config/xremap/config.yml" /etc/xremap/config.yml
  check assert "/etc/xremap/config.yml is root:root 0644, so the user cannot make xremap run its commands" eq "$(root stat -c '%U:%G %a' /etc/xremap/config.yml)" "root:root 644"
  check assert "xremap config validates" xremap-wlroots --validate-config /etc/xremap/config.yml
  check assert "xremap.path enabled" unit_enabled xremap.path
  check assert "xremap.path active" unit_active xremap.path
  check assert "xremap.service runs as the xremap user" eq "$(systemctl show xremap.service -p User --value)" xremap
  check assert "xremap.service is active while sway runs" system_unit_active_when_sway_runs xremap.service

  for u in tailscaled nix-daemon.service; do
    check assert "$u enabled" unit_enabled "$u"
    check assert "$u active" unit_active "$u"
  done

  if tailscale_logged_out; then
    warn_check "tailscale operator is $VEKRONA_USER (tailscaled forgets it across restarts until the first login: run 'tailscale up', then ./install.sh 40)" tailscale_operator_is_user
  else
    check assert "tailscale operator is $VEKRONA_USER" tailscale_operator_is_user
  fi

  if has_sshd; then
    check assert "sshd drop-in matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/ssh/sshd_config.d/10-vekrona.conf" "$SSHD_DROPIN"
    check assert "sshd refuses password logins" eq "$(sshd_setting passwordauthentication)" no
    check assert "sshd refuses keyboard-interactive logins" eq "$(sshd_setting kbdinteractiveauthentication)" no
    check assert "sshd accepts public keys only" eq "$(sshd_setting authenticationmethods)" publickey
    check assert "sshd refuses root logins" eq "$(sshd_setting permitrootlogin)" no
  fi
  warn_check "firewalld is running (it limits ssh to the tailnet)" firewalld_active
  if firewalld_active; then
    check assert "$TAILNET_ZONE_FILE matches the checkout" root_files_equal "$VEKRONA_ROOT/etc/firewalld/zones/tailnet.xml" "$TAILNET_ZONE_FILE"
    for cidr in "${TAILNET_SOURCES[@]}"; do
      check assert "$cidr is in the $TAILNET_ZONE zone" eq "$(root firewall-cmd --get-zone-of-source="$cidr")" "$TAILNET_ZONE"
    done
    warn_check "$TAILNET_IFACE is in the $TAILNET_ZONE zone (the sources decide anyway; NetworkManager may hold the interface elsewhere)" eq "$(root firewall-cmd --get-zone-of-interface="$TAILNET_IFACE")" "$TAILNET_ZONE"
    check assert "the $TAILNET_ZONE zone opens ssh and nothing else" eq "$(root firewall-cmd --zone="$TAILNET_ZONE" --list-services)" ssh
    # Assigned first: a failing firewall-cmd inside "$(...)" in a check's arguments would only read as an empty answer, "closed".
    ssh_open_running="$(zones_allowing_ssh)"
    ssh_open_permanent="$(zones_allowing_ssh --permanent)"
    default_zone="$(root firewall-cmd --get-default-zone)"
    check assert "no zone but $TAILNET_ZONE lets ssh in (stage 40 keeps ssh while it is used from outside the tailnet: run it from the tailnet)" eq "$ssh_open_running" ""
    check assert "no zone but $TAILNET_ZONE lets ssh in after the next reload" eq "$ssh_open_permanent" ""
    check assert "the default zone is $DEFAULT_ZONE" eq "$default_zone" "$DEFAULT_ZONE"
    for service in "${DEFAULT_ZONE_SERVICES[@]}"; do
      check assert "the $service service is open in the $DEFAULT_ZONE zone (permanent)" firewall_query --permanent --zone="$DEFAULT_ZONE" --query-service="$service"
    done
    high_port_zones="$(zones_open_to_high_ports)"
    check assert "no zone with an interface opens TCP 1025-65535 (a NetworkManager connection may pin one: nmcli connection modify <connection> connection.zone '')" eq "$high_port_zones" ""
    check assert "the default zone lets AirPlay's UDP $AIRPLAY_UDP_LO-$AIRPLAY_UDP_HI in" zone_allows_udp_range "$default_zone" "$AIRPLAY_UDP_LO" "$AIRPLAY_UDP_HI"
  fi
fi

if ran 45-auth; then
  check assert "authselect selects custom/vekrona with its four features" authselect_selection_ok
  for f in system-auth password-auth; do
    check assert "both pam_u2f template lines pinned to pam://vekrona in the profile's $f" vekrona_pam_u2f_lines_ok "/etc/authselect/custom/vekrona/$f" 2
    check assert "the one enabled pam_u2f line pinned to pam://vekrona in /etc/pam.d/$f" vekrona_pam_u2f_lines_ok "/etc/pam.d/$f" 1
  done
  for pam in vekrona-lock-password vekrona-lock-u2f vekrona-lock-fprint; do
    check assert "$pam equals the repo file" root_files_equal "$VEKRONA_ROOT/etc/pam.d/$pam" "/etc/pam.d/$pam"
  done
  check assert "stale dankshell-u2f removed" path_absent /etc/pam.d/dankshell-u2f
  check assert "vekrona-lock-u2f carries the same pam_u2f arguments as system-auth (PIN and touch, /etc/u2f_mappings)" file_grep_q -xF "auth     required  $PAM_U2F_VEKRONA" /etc/pam.d/vekrona-lock-u2f
  check assert "the pam_u2f registration file is $U2F_MAPPINGS in every PAM stack" contains "authfile=$U2F_MAPPINGS" "$PAM_U2F_VEKRONA"
  if root test -e "$U2F_MAPPINGS"; then
    check assert "$U2F_MAPPINGS is root:root 0644 (the lock screen reads it as the user), so no process of the user can register a key" eq "$(root stat -c '%U:%G %a' "$U2F_MAPPINGS")" "root:root 644"
  elif [[ -e "$(u2f_keys_path)" ]]; then
    check assert "$(u2f_keys_path) was moved into $U2F_MAPPINGS (rerun ./install.sh 45)" false
  fi
  check assert "no plugged-in YubiKey acts as a keyboard (a touch would type an OTP into the lock screen as a wrong password; run: ykman config usb --disable OTP, then replug the key)" yubico_has_no_keyboard
  warn_check "fprintd sees a fingerprint reader (with-fingerprint is enabled regardless; none present, plug in a USB reader)" fprintd_sees_reader

  crypttab_content="$(read_crypttab)"
  fido2_tokens="$(crypttab_fido2_tokens "$crypttab_content")"
  fido2_token_found=0
  while IFS=$'\t' read -r crypt_name crypt_dev token_state; do
    if [[ -z "$crypt_name" ]]; then
      continue
    fi
    if [[ "$token_state" == yes ]]; then
      fido2_token_found=1
      check assert "crypttab entry $crypt_name has fido2-device (token on $crypt_dev)" crypttab_line_has_fido2 "$crypttab_content" "$crypt_name"
    else
      check assert "crypttab entry $crypt_name has no fido2-device (no token on $crypt_dev)" not crypttab_line_has_fido2 "$crypttab_content" "$crypt_name"
    fi
  done <<<"$fido2_tokens"
  if [[ "$fido2_token_found" -eq 1 ]]; then
    initramfs_kvers="$(kvers_with_initramfs)"
    default_kver="$(basename "$(root grubby --default-kernel)")"
    default_kver="${default_kver#vmlinuz-}"
    check assert "default kernel $default_kver has an initramfs" file_exists "$(initramfs_path "$default_kver")"
    while IFS= read -r kver; do
      check assert "initramfs for $kver carries FIDO2 unlock" initramfs_carries_fido2 "$kver"
    done <<<"$initramfs_kvers"
  fi

  warn_check "$U2F_MAPPINGS or fingerprint prints registered for $VEKRONA_USER" user_has_touch_credentials
fi

if ran 15-mac; then
  check assert "wl module built for the running kernel iff Broadcom wl Wi-Fi present" present_iff has_broadcom_wl_wifi module_built_for_running_kernel wl
  check assert "broadcom-wl modprobe drop-in iff Broadcom wl Wi-Fi present" present_iff has_broadcom_wl_wifi file_exists /etc/modprobe.d/vekrona-broadcom-wl.conf
  check assert "apple-gmux modprobe drop-in iff Apple dual-GPU" present_iff has_apple_gmux_dual_gpu file_exists /etc/modprobe.d/vekrona-apple-gmux.conf
  check assert "facetimehd module built for the running kernel iff FaceTime HD camera present" present_iff has_facetime_hd_camera module_built_for_running_kernel facetimehd
  if has_facetime_hd_camera; then
    check assert "facetimehd firmware.bin matches the pinned sha256" facetimehd_firmware_is_current
  fi
  check assert "libva-intel-driver installed" pkg_installed libva-intel-driver
  check assert "mbp12 audio modprobe drop-in iff MacBookPro12,1" present_iff is_macbookpro12_1 file_exists /etc/modprobe.d/vekrona-mbp12-audio.conf
  check assert "brcmfmac resume hook iff BCM43602 Wi-Fi" present_iff has_brcmfmac_43602 file_executable /etc/systemd/system-sleep/vekrona-brcmfmac-resume
  if has_broadcom_wl_wifi; then
    warn_check "wl module loaded (reboot pending if wl was just built)" module_loaded wl
  fi
fi

if ran 50-user; then
  mapfile -t link_dirs < <(vekrona_link_dirs)
  stale_links="$(vekrona_links "${link_dirs[@]}" | while IFS= read -r l; do
    if is_legacy_link_target "$(readlink "$l")"; then printf '%s ' "$l"; fi
  done)"
  check assert "every vekrona symlink points into $VEKRONA_ROOT (stale: ${stale_links:-none})" eq "$stale_links" ""
  stale_bad_links="$(vekrona_links --stale "${link_dirs[@]}" | tr '\n' ' ')"
  check assert "no vekrona symlink points to a missing or git-ignored file (stale: ${stale_bad_links:-none})" eq "$stale_bad_links" ""
  ghostty_links="$(vekrona_links "$HOME/.config/ghostty" | tr '\n' ' ')"
  check assert "no vekrona symlink left under ~/.config/ghostty (vekrona ships no Ghostty config; found: ${ghostty_links:-none})" eq "$ghostty_links" ""
  check assert "~/.config/autostart/nvidia-settings-user.desktop links to $VEKRONA_ROOT/config/autostart/nvidia-settings-user.desktop" \
    eq "$(readlink "$HOME/.config/autostart/nvidia-settings-user.desktop")" "$VEKRONA_ROOT/config/autostart/nvidia-settings-user.desktop"
  check assert "~/.config/autostart/sealertauto.desktop links to $VEKRONA_ROOT/config/autostart/sealertauto.desktop" \
    eq "$(readlink "$HOME/.config/autostart/sealertauto.desktop")" "$VEKRONA_ROOT/config/autostart/sealertauto.desktop"
  check assert "the systemd user manager generates no nvidia-settings autostart unit (the Hidden=true override took effect)" \
    path_absent "$XDG_RUNTIME_DIR/systemd/generator.late/app-nvidia\\x2dsettings\\x2duser@autostart.service"
  check assert "sway config.d exists (personal Sway settings, included last by the shared config)" dir_exists "$HOME/.config/sway/config.d"
  check assert "sway config validates" env WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway --unsupported-gpu --validate -c "$HOME/.config/sway/config"
  check assert "sway panel scale drop-in present iff an internal panel is connected" present_iff has_internal_panel file_exists "$SWAY_PANEL_SCALE_DROPIN"
  check assert "system X11 keymap converts to Sway's XKB environment" vekrona-xkb-env
  check assert "xremap config validates" xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml"
  check assert "sway keybindings all described" vekrona-keybindings --check
  check assert "vekrona-keybindings --list has workspace 10 bindings" bash -c "vekrona-keybindings --list | grep -qF 'workspace 1…10'"
  check assert "vekrona-keybindings --list has the help binding" bash -c "vekrona-keybindings --list | grep -qF 'Show keybindings help'"
  check assert "the old xremap user service is not enabled (xremap is a system service now)" not user_unit_enabled xremap
  check assert "syncthing.service enabled" user_unit_enabled syncthing
  check assert "syncthing waits for the network before it starts (nm-online drop-in linked and loaded)" contains "nm-online" "$(systemctl --user show syncthing.service -p ExecStartPre --value)"
  check assert "vekrona-app-switch.service enabled" user_unit_enabled vekrona-app-switch.service
  check assert "vekrona-shell Quickshell config linked into ~/.config/quickshell" eq "$(readlink -f "$HOME/.config/quickshell/vekrona-shell")" "$(readlink -f "$VEKRONA_ROOT/config/vekrona-shell")"
  check assert "vekrona-shell reaches the shared Vekrona module" file_exists "$HOME/.config/quickshell/vekrona-shell/Vekrona/qmldir"
  check assert "vekrona-shell.service enabled" user_unit_enabled vekrona-shell.service
  check assert "tailscale-systray.service enabled" user_unit_enabled tailscale-systray.service
  check assert "tailscale-systray.service waits for the StatusNotifierWatcher" contains org.kde.StatusNotifierWatcher "$(systemctl --user show tailscale-systray.service -p ExecStartPre --value)"
  check assert "vekrona-cliphist.service enabled" user_unit_enabled vekrona-cliphist.service
  check assert "vekrona-idle.service enabled" user_unit_enabled vekrona-idle.service
  check assert "vekrona-lid.service enabled (the lid switch and the sleep key are Sway's, which locks before it suspends)" user_unit_enabled vekrona-lid.service
  check assert "vekrona-lock-guard.service loaded (vekrona-lock holds it while the screen is unlocked, and a missing unit would let the machine suspend unlocked)" user_unit_loaded vekrona-lock-guard.service
  check assert "vekrona-session-teardown.service enabled" user_unit_enabled vekrona-session-teardown.service
  check assert "vekrona-session-teardown.service holds the shutdown delay lock while sway runs" present_iff sway_runs session_teardown_holds_shutdown_lock
  check assert "vekrona-shell.service active without automatic restarts while sway runs" present_iff sway_runs user_unit_active_without_restarts vekrona-shell.service
  check assert "~/.config/DankMaterialShell is absent" path_absent "$HOME/.config/DankMaterialShell"
  check assert "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/danklinux-shell is absent" path_absent "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/danklinux-shell"
  check assert "vekrona-night.service linked" file_exists "$HOME/.config/systemd/user/vekrona-night.service"
  check assert "vekrona-weather.timer enabled" user_unit_enabled vekrona-weather.timer
  check assert "vekrona-calendar.timer enabled" user_unit_enabled vekrona-calendar.timer
  check assert "vekrona-update-notify.service linked" file_exists "$HOME/.config/systemd/user/vekrona-update-notify.service"
  check assert "vekrona-update-notify.path linked" file_exists "$HOME/.config/systemd/user/vekrona-update-notify.path"
  check assert "vekrona-update-notify.service enabled" user_unit_enabled vekrona-update-notify.service
  check assert "vekrona-update-notify.path enabled" user_unit_enabled vekrona-update-notify.path
  check assert "vekrona-update-notify.path active while sway runs" active_when_sway_runs vekrona-update-notify.path
  for tool in vekrona-update-ask vekrona-update-notify vekrona-update-start; do
    check assert "$tool resolves on PATH" bash -c 'command -v "$1" >/dev/null' _ "$tool"
  done
  check assert "vekrona-weather.timer active while sway runs" active_when_sway_runs vekrona-weather.timer
  check assert "vekrona-calendar.timer active while sway runs" active_when_sway_runs vekrona-calendar.timer
  check assert "vekrona-weather.service runs successfully while sway runs" runs_when_sway_runs vekrona-weather.service
  check assert "vekrona-calendar.service runs successfully while sway runs" runs_when_sway_runs vekrona-calendar.service
  check assert "khal config linked" eq "$(readlink -f "$HOME/.config/khal/config")" "$(readlink -f "$VEKRONA_ROOT/config/khal/config")"
  check assert "vdirsyncer example linked" eq "$(readlink -f "$HOME/.config/vdirsyncer/config.example")" "$(readlink -f "$VEKRONA_ROOT/config/vdirsyncer/config.example")"
  check assert_file_contains /etc/geoclue/conf.d/90-vekrona.conf "^allowed=true\$"
  check assert "vekrona-errors.service linked" file_exists "$HOME/.config/systemd/user/vekrona-errors.service"
  check assert "vekrona-errors-failed.service linked" file_exists "$HOME/.config/systemd/user/vekrona-errors-failed.service"
  check assert "vekrona-errors.service enabled" user_unit_enabled vekrona-errors
  check assert "vekrona-audio-watchdog.service linked" file_exists "$HOME/.config/systemd/user/vekrona-audio-watchdog.service"
  check assert "vekrona-audio-watchdog.service enabled" user_unit_enabled vekrona-audio-watchdog
  check assert "vekrona-audio-watchdog resolves on PATH" bash -c "command -v vekrona-audio-watchdog >/dev/null"
  check assert "pipewire-config-raop installed" pkg_installed pipewire-config-raop
  check assert "pipewire-utils installed" pkg_installed pipewire-utils
  for skills_dir in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
    check assert "vekrona-diagnose skill linked: $skills_dir" file_exists "$skills_dir/vekrona-diagnose/SKILL.md"
  done
  check assert "python3-gobject installed" pkg_installed python3-gobject
  check assert "vekrona-error --help runs" vekrona-error --help
  errors_store_dir="${XDG_STATE_HOME:-$HOME/.local/state}/vekrona/errors"
  if [[ -d "$errors_store_dir" ]]; then
    check assert "error store directory mode is 0700" dir_mode_is "$errors_store_dir" 700
  else
    log "error store directory not created yet (vekrona-errors.service has not run in a live session), skipping its mode check"
  fi
  check assert "AtkynsonMono Nerd Font installed" bash -c "fc-list | grep -q 'AtkynsonMono Nerd'"
  check assert "vekrona fontconfig linked" file_exists "$HOME/.config/fontconfig/conf.d/50-vekrona-fonts.conf"
  check assert_file_contains "$HOME/.config/wireplumber/wireplumber.conf.d/50-vekrona-no-libcamera.conf" '^[[:space:]]*monitor\.libcamera[[:space:]]*=[[:space:]]*disabled[[:space:]]*$'
  check assert_file_contains "$HOME/.config/wireplumber/wireplumber.conf.d/50-vekrona-audio.conf" '^[[:space:]]*session\.dont-restore-off-profile[[:space:]]*=[[:space:]]*true[[:space:]]*$'
  check assert_file_contains "$HOME/.config/wireplumber/wireplumber.conf.d/50-vekrona-audio.conf" '^[[:space:]]*node\.restore-default-targets[[:space:]]*=[[:space:]]*false[[:space:]]*$'
  check assert_file_contains "$HOME/.config/wireplumber/wireplumber.conf.d/50-vekrona-audio.conf" '^[[:space:]]*\{[[:space:]]*device\.name[[:space:]]*=[[:space:]]*"~alsa_card\.usb-MACROSILICON\.\*"'
  check assert_file_contains "$HOME/.config/wireplumber/wireplumber.conf.d/50-vekrona-audio.conf" '^[[:space:]]*device\.disabled[[:space:]]*=[[:space:]]*true[[:space:]]*$'
  check assert_file_contains "$HOME/.config/pipewire/pipewire.conf.d/50-vekrona-raop.conf" '^[[:space:]]*module\.raop[[:space:]]*=[[:space:]]*false[[:space:]]*$'
  check assert_file_contains "$HOME/.config/pipewire/pipewire.conf.d/50-vekrona-raop.conf" '^[[:space:]]*sess\.latency\.msec[[:space:]]*=[[:space:]]*247\.45[[:space:]]*$'
  check assert "fc-match sans-serif -> Atkinson Hyperlegible Next" bash -c "fc-match sans-serif | grep -q 'Atkinson Hyperlegible Next'"
  check assert "fc-match sans-serif (Ukrainian i, U+0456) -> Inter" bash -c "fc-match 'sans-serif:charset=0456' | grep -q Inter"
  check assert "fc-match monospace -> AtkynsonMono Nerd Font" bash -c "fc-match monospace | grep -q 'AtkynsonMono Nerd Font'"
  check assert "gsettings font-name: Atkinson Hyperlegible Next 11.25" gsettings_eq org.gnome.desktop.interface font-name "Atkinson Hyperlegible Next 11.25"
  check assert "gsettings document-font-name: Atkinson Hyperlegible Next 11.25" gsettings_eq org.gnome.desktop.interface document-font-name "Atkinson Hyperlegible Next 11.25"
  check assert "gsettings monospace-font-name: AtkynsonMono Nerd Font 10.5" gsettings_eq org.gnome.desktop.interface monospace-font-name "AtkynsonMono Nerd Font 10.5"
  check assert "vekrona-lock resolves on PATH" bash -c "command -v vekrona-lock >/dev/null"
  check assert "vekrona-lock Quickshell config linked into ~/.config/quickshell" eq "$(readlink -f "$HOME/.config/quickshell/vekrona-lock")" "$(readlink -f "$VEKRONA_ROOT/config/vekrona-lock")"
  check assert "vekrona-lock.service linked" eq "$(readlink -f "$HOME/.config/systemd/user/vekrona-lock.service")" "$(readlink -f "$VEKRONA_ROOT/config/systemd-user/vekrona-lock.service")"
  check assert "vekrona-agent --help runs" bash -c "vekrona-agent --help >/dev/null"
  check assert "qalc resolves (the launcher's /calc)" bash -c "command -v qalc >/dev/null"

  for app_id in "${VEKRONA_X11_FLATPAKS[@]}"; do
    flatpak_installed "$app_id" || continue
    override="$(flatpak override --user --show "$app_id" 2>/dev/null || true)"
    check assert "flatpak x11 override set: $app_id" contains x11 "$override"
  done
  if flatpak_installed md.obsidian.Obsidian; then
    override="$(flatpak override --user --show md.obsidian.Obsidian 2>/dev/null || true)"
    check assert "obsidian flatpak keeps its wayland socket" not_contains '!wayland' "$override"
  fi
  if flatpak_installed org.signal.Signal; then
    override="$(flatpak override --user --show org.signal.Signal 2>/dev/null || true)"
    check assert "signal flatpak keeps its key in gnome-keyring" contains SIGNAL_PASSWORD_STORE=gnome-libsecret "$override"
  fi

  firefox_profiles_dir="$(firefox_profile_root)" || die "cannot resolve the Firefox profile root"
  firefox_profiles_ini="$firefox_profiles_dir/profiles.ini"
  for webapp_dir in "$VEKRONA_ROOT"/config/firefox/webapps/*/; do
    webapp="$(basename "$webapp_dir")"
    check assert "$webapp webapp profile registered" grep -q "vekrona-$webapp" "$firefox_profiles_ini"
    check assert_file_contains "$firefox_profiles_dir/vekrona-$webapp/chrome/userChrome.css" "^/\\* vekrona-render-theme: "
    check assert "$webapp webapp icon installed" file_exists "$HOME/.local/share/icons/hicolor/scalable/apps/vekrona-$webapp.svg"
    check assert_file_contains "$HOME/.local/share/applications/vekrona-$webapp.desktop" "^Icon=vekrona-$webapp\$"
  done
  check assert "vekrona-theme installed" file_exists "$HOME/.local/bin/vekrona-theme"
  check assert_file_contains "$HOME/.config/gtk-3.0/gtk.css" "^/\\* vekrona-render-theme: "
  check assert_file_contains "$HOME/.config/gtk-4.0/gtk.css" "^/\\* vekrona-render-theme: "
  check assert_file_contains "$HOME/.config/qt6ct/qt6ct.conf" "^# vekrona-render-theme: "
  check assert_file_contains "$HOME/.config/qt6ct/colors/vekrona.conf" "^# vekrona-render-theme: "
  check assert_file_contains "$HOME/.config/sway/config.d/90-vekrona-design.conf" "^# vekrona-render-theme: "
  for browser_mime in "${VEKRONA_BROWSER_MIMES[@]}"; do
    check assert "Firefox is the default handler of $browser_mime" eq "$(xdg-mime query default "$browser_mime")" "$VEKRONA_BROWSER_DESKTOP"
  done
  firefox_default_profile="$(awk -F= '/^\[Install/ {in_install=1; next} /^\[/ {in_install=0} in_install && $1 == "Default" {print $2; exit}' "$firefox_profiles_ini" 2>/dev/null || true)"
  if [[ -n "$firefox_default_profile" ]]; then
    firefox_root_dir="$(firefox_profile_root)" || die "cannot resolve the Firefox profile root"
    firefox_default_profile="$firefox_root_dir/$firefox_default_profile"
    check assert_file_contains "$firefox_default_profile/user.js" "^// vekrona-render-theme: "
    check assert_file_contains "$firefox_default_profile/chrome/userChrome.css" "^/\\* vekrona-render-theme: "
  fi
  recorded_theme_name="$(cat "$(vekrona_theme_name_file)" 2>/dev/null || true)"
  check assert "recorded theme is dark or light (got '$recorded_theme_name')" bash -c '[[ "$1" == dark || "$1" == light ]]' _ "$recorded_theme_name"
  case "$recorded_theme_name" in
    light) expected_gtk_theme=adw-gtk3 expected_color_scheme=prefer-light ;;
    *) expected_gtk_theme=adw-gtk3-dark expected_color_scheme=prefer-dark ;;
  esac
  check assert "GTK theme follows the $recorded_theme_name mode: $expected_gtk_theme" gsettings_eq org.gnome.desktop.interface gtk-theme "$expected_gtk_theme"
  check assert "color-scheme follows the $recorded_theme_name mode: $expected_color_scheme" gsettings_eq org.gnome.desktop.interface color-scheme "$expected_color_scheme"
  check assert "active-theme.json is valid, has both modes each with a tokens object, and matches the recorded mode" python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
for mode in ("dark", "light"):
    assert isinstance(d.get(mode), dict), mode
    assert isinstance(d[mode].get("tokens"), dict) and d[mode]["tokens"], (mode, "tokens")
assert d.get("mode") == sys.argv[2], d.get("mode")
assert isinstance(d.get("metrics"), dict), "metrics"
' "$(vekrona_active_theme_file)" "$recorded_theme_name"
  check assert "vekrona-lock resolves import \"Vekrona\" through ~/.config/quickshell" file_exists "$HOME/.config/quickshell/vekrona-lock/Vekrona/qmldir"
  check assert "vekrona-app-switch reads tokens.json through ~/.config/quickshell" test -r "$HOME/.config/quickshell/vekrona-app-switch/tokens.json"

  check assert "no stale vekrona-gpu.conf from an earlier install (the GPU is chosen at login by vekrona-gpu-env)" path_absent "$HOME/.config/environment.d/vekrona-gpu.conf"
  check assert "vekrona-gpu-env runs" vekrona-gpu-env
  check assert "systemd --user manager environment has no QSG_RHI_BACKEND (Vulkan deadlocks the lock screen)" not_contains 'QSG_RHI_BACKEND' "$(systemctl --user show-environment 2>/dev/null || true)"

  user_path="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')"
  warn_check "$HOME/.local/bin in systemd user PATH" contains "$HOME/.local/bin" "$user_path"
  warn_check "$HOME/.nix-profile/bin in systemd user PATH" contains "$HOME/.nix-profile/bin" "$user_path"

  check assert "devbox runs" "$HOME/.nix-profile/bin/devbox" version
fi

if ran 60-gaming; then
  check assert "scb is executable" bash -c "[[ -x /usr/local/bin/scb ]]"
  for p in gamescope mangohud gamemode steam python3-vdf; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "scopebuddy config present" file_exists "$HOME/.config/scopebuddy/scb.conf"

  steam_config_vdf="$HOME/.local/share/Steam/config/config.vdf"
  if [[ -e "$steam_config_vdf" ]]; then
    steam_vdf_check="$(cat <<'PY'
import sys
import vdf


def find_key(d, key):
    if key in d:
        return key
    for k in d:
        if isinstance(k, str) and k.lower() == key.lower():
            return k
    return None


def child(d, key):
    found = find_key(d, key)
    assert found is not None, f'missing section: {key}'
    value = d[found]
    assert isinstance(value, dict), f'expected a section at {key!r}, found {type(value).__name__}'
    return value


with open(sys.argv[1]) as f:
    data = vdf.load(f)

node = data
for key in ('InstallConfigStore', 'Software', 'Valve', 'Steam', 'CompatToolMapping'):
    node = child(node, key)

zero_key = find_key(node, '0')
assert zero_key is not None, 'no CompatToolMapping entry "0"'
entry = node[zero_key]
name_key = find_key(entry, 'name')
assert name_key is not None, 'no name field in CompatToolMapping "0"'
assert entry[name_key].lower() == 'proton_experimental', entry[name_key]
PY
)"
    check assert "Steam Play for all titles enabled (proton_experimental)" python3 -I -c "$steam_vdf_check" "$steam_config_vdf"
  else
    warn_check "Steam never launched: launch Steam once, quit it, then run ./install.sh 60" false
  fi
fi

if ran 65-login-manager; then
  dm_target="$(dm_unit_target 2>/dev/null || true)"
  if dm_is_greetd; then
    verify_greetd_enabled
  elif [[ -n "$dm_target" ]]; then
    log "another display manager enabled ($dm_target); skipping greetd checks, 90a-switch-dm is the migration path"
  else
    die "no display manager enabled"
  fi
fi

if ran 90a-switch-dm || ran 90b-remove; then
  verify_greetd_enabled
  warn_check "gdm not present or disabled" gdm_absent_or_disabled
  warn_check "secrets service reachable" busctl --user status org.freedesktop.secrets
  if ran 90b-remove; then
    for p in omedora hyprland keyd dunst; do
      check assert "package absent: $p" pkg_absent "$p"
    done
  fi
  declare -a desktop_pkgs
  read_pkg_list desktop_pkgs vekrona_desktop_pkgs
  for p in "${desktop_pkgs[@]}"; do
    check assert "protected desktop package present: $p" pkg_installed "$p"
  done
  for f in /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/logind.conf.d/vekrona-idle.conf /etc/systemd/sleep.conf.d/vekrona.conf /etc/systemd/oomd.conf.d/vekrona.conf /etc/systemd/coredump.conf.d/50-vekrona.conf; do
    check assert "override still present: $f" file_exists "$f"
  done
fi

log "verify summary: ok=$ok_count warn=$warn_count"
