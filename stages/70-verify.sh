#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/authselect-vekrona.sh"
source "$ROOT/lib/luks-fido2.sh"
source "$ROOT/lib/facetimehd.sh"
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
file_absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
dir_exists() { [[ -d "$1" ]]; }
group_member() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qx "$2"; }
gsettings_eq() { [[ "$(user_gsettings get "$1" "$2")" == "'$3'" ]]; }
not_repo_enabled() { ! repo_enabled "$1"; }
copr_enabled() { repo_enabled "$(copr_id "$1")"; }
unit_enabled() { eq "$(systemctl is-enabled "$1" 2>/dev/null || true)" enabled; }
unit_active() { eq "$(systemctl is-active "$1" 2>/dev/null || true)" active; }
user_unit_enabled() { eq "$(systemctl --user is-enabled "$1" 2>/dev/null || true)" enabled; }
pkg_absent() { ! pkg_installed "$1"; }
gdm_absent_or_disabled() { ! pkg_installed gdm || ! unit_enabled gdm; }
file_executable() { [[ -x "$1" ]]; }
module_loaded() { [[ -d "/sys/module/$1" ]]; }
module_built_for_running_kernel() { modinfo -k "$(uname -r)" "$1" >/dev/null 2>&1; }
nvidia_module_present_for() { modinfo -k "$1" nvidia >/dev/null 2>&1; }
root_files_equal() { root cmp -s "$1" "$2"; }
user_has_touch_credentials() { [[ -e "$HOME/.config/Yubico/u2f_keys" ]] || root test -e "/var/lib/fprint/$VEKRONA_USER"; }
vekrona_pam_u2f_lines_ok() {
  local content pinned total
  content="$(<"$1")"
  pinned="$(count_occurrences "$content" "$PAM_U2F_VEKRONA")"
  total="$(count_occurrences "$content" "pam_u2f.so")"
  [[ "$pinned" -eq "$2" && "$total" -eq "$2" ]]
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

verify_greetd_active() {
  check assert "greetd enabled" greetd_enabled
  check assert "display-manager.service points to greetd" dm_is_greetd
  check assert "default target is graphical.target" default_target_is_graphical
}

if ran 00-repos; then
  check assert "repo enabled: rpmfusion-nonfree" repo_enabled rpmfusion-nonfree
  for section in free nonfree; do
    check assert_repo_key_trusted "$(rpmfusion_key_repo "$section")"
    check assert "rpmfusion-$section.repo takes its key only from the pinned key file" rpmfusion_repo_file_uses_pinned_key "$section"
  done
  check assert "repo enabled: fedora-cisco-openh264" repo_enabled fedora-cisco-openh264
  check assert "repo enabled: 1password" repo_enabled 1password
  check assert_repo_key_trusted 1password
  check assert "/etc/yum.repos.d/1password.repo matches repo" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/1password.repo" /etc/yum.repos.d/1password.repo
  for c in "${VEKRONA_COPRS[@]}"; do
    check assert "copr enabled: $c" copr_enabled "$c"
  done
fi

if ran 10-nvidia; then
  check assert "akmod-nvidia installed" pkg_installed akmod-nvidia
  check assert "libva-nvidia-driver installed" pkg_installed libva-nvidia-driver

  nvidia_disk_version="$(modinfo -F version nvidia 2>/dev/null || true)"
  nvidia_loaded_version="$(cat /sys/module/nvidia/version 2>/dev/null || true)"
  if [[ -n "$nvidia_loaded_version" && "$nvidia_disk_version" == "$nvidia_loaded_version" ]]; then
    modeset="$(root cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo '?')"
    check assert "nvidia_drm modeset=Y" eq "$modeset" Y
    gsp="$(nvidia-smi -q 2>/dev/null | grep 'GSP Firmware' || true)"
    check assert "GSP firmware disabled (N/A)" contains 'N/A' "$gsp"
    check assert "nvidia module is proprietary, not Open" not_contains 'Open' "$(cat /proc/driver/nvidia/version 2>/dev/null || true)"
  else
    warn_check "nvidia_drm modeset=Y (reboot pending: disk=$nvidia_disk_version loaded=$nvidia_loaded_version)" false
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
  check assert "akmods@$(uname -r) regenerates the initramfs after its build" akmods_dropin_active "$(uname -r)"

  for u in nvidia-suspend nvidia-resume nvidia-hibernate; do
    check assert "$u enabled" unit_enabled "$u"
  done

  check assert "versionlock: akmod-nvidia" versionlock_has akmod-nvidia

  for d in /lib/modules/*/; do
    kver="$(basename "$d")"
    [[ -e "/boot/vmlinuz-$kver" ]] || continue
    warn_check "nvidia module present for kernel $kver" nvidia_module_present_for "$kver"
  done

  check assert "cuda-fedora44-x86_64 enabled" repo_enabled cuda-fedora44-x86_64
  check assert "cuda-fedora43-x86_64 absent" not_repo_enabled cuda-fedora43-x86_64
fi

if ran 20-snapper; then
  check assert "snapper config: NUMBER_LIMIT=10" root grep -qE '^NUMBER_LIMIT="10"$' /etc/snapper/configs/root
  check assert "snapper config: TIMELINE_CREATE=no" root grep -qE '^TIMELINE_CREATE="no"$' /etc/snapper/configs/root
  check assert "snapper actions file present" file_exists /etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions
  check assert "libdnf5-plugin-actions installed" pkg_installed libdnf5-plugin-actions
  check assert "snapper-cleanup.timer enabled" unit_enabled snapper-cleanup.timer

  snapper_csv() { root snapper --csvout --no-headers list --columns number,type,cleanup; }
  csv_row_matches() { grep -qE -- "$1" <<<"$snapshots_csv"; }

  n0="$(snapper_csv | tail -1 | cut -d, -f1)"
  root dnf install -y hello
  root dnf remove -y hello
  snapshots_csv="$(snapper_csv)"
  n1="$(tail -1 <<<"$snapshots_csv" | cut -d, -f1)"
  check assert "at least 2 new snapshots from install/remove round-trip" ge "$((n1 - n0))" 2
  check assert "pre snapshot has cleanup=number" csv_row_matches '^[0-9]+,pre,number$'
  check assert "post snapshot has cleanup=number" csv_row_matches '^[0-9]+,post,number$'

  nix_mounted_from_subvol() { [[ "$(findmnt -no SOURCE /nix 2>/dev/null)" == *"[/nix]" ]]; }
  check assert "/nix mounted from subvolume nix" nix_mounted_from_subvol

  nix_fstab_line="$(fstab_line_for_mountpoint /nix)" || die "no fstab entry for /nix"
  home_fstab_line="$(fstab_line_for_mountpoint /home)" || die "no fstab entry for /home"
  read -r nix_device _ _ nix_options _ _ <<<"$nix_fstab_line"
  read -r home_device _ <<<"$home_fstab_line"
  check assert "fstab /nix options contain subvol=nix" contains "subvol=nix" "$nix_options"
  check assert "fstab /nix device matches /home device" eq "$nix_device" "$home_device"

  check assert "/nix migration marker present" file_exists /nix/.vekrona-migrated
  check assert "/nix.pre-vekrona backup absent" file_absent /nix.pre-vekrona
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

  check assert "package installed: tuned-ppd" pkg_installed tuned-ppd
  check assert "tuned.service enabled" unit_enabled tuned
  check assert "tuned-ppd.service enabled" unit_enabled tuned-ppd
  warn_check "power profiles D-Bus name answers: net.hadess.PowerProfiles" \
    busctl introspect net.hadess.PowerProfiles /net/hadess/PowerProfiles

  check assert "flathub flatpak remote present and enabled system-wide" flatpak_remote_system_enabled flathub
  check assert "dev.zed.Zed flatpak installed" flatpak_installed dev.zed.Zed

  declare -a desktop_pkgs
  read_pkg_list desktop_pkgs vekrona_desktop_pkgs
  for p in "${desktop_pkgs[@]}"; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "package absent: ffmpeg-free" pkg_absent ffmpeg-free

  pkg_from_repo() { dnf repoquery --installed --qf '%{from_repo}\n' "$1" 2>/dev/null || true; }
  for p in "${!VEKRONA_PINNED_PKGS[@]}"; do
    check assert "package installed from pinned repo: $p" eq "$(pkg_from_repo "$p")" "${VEKRONA_PINNED_PKGS[$p]}"
  done

  for stale in "$HOME/.local/zed.app" "$HOME/.local/bin/zed" "$HOME/.local/share/applications/dev.zed.Zed.desktop"; do
    check assert "no stale tarball Zed at $stale (if present, remove it: it shadows the dev.zed.Zed Flatpak)" \
      file_absent "$stale"
  done
fi

if ran 40-system; then
  check assert_file_contains /etc/greetd/config.toml 'user = "greetd"'
  check assert "greetd creates /var/cache/tuigreet on start" file_exists /etc/systemd/system/greetd.service.d/vekrona-tuigreet-cache.conf
  check assert "no tmpfiles.d entry for greetd's cache dir (dracut copies it into an initramfs without the user)" file_absent /etc/tmpfiles.d/vekrona-tuigreet.conf
  check assert "/var/cache/tuigreet exists" dir_exists /var/cache/tuigreet
  check assert "/var/cache/tuigreet owned by greetd" owned_by /var/cache/tuigreet greetd
  check assert "default error mutes installed" file_exists /etc/vekrona/errors-mute.d/10-vendor-noise.conf
  check assert "logind inhibit-delay drop-in present" file_exists /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf
  check assert "oomd drop-in present" file_exists /etc/systemd/oomd.conf.d/vekrona.conf
  check assert "usb autosuspend drop-in present iff not a laptop" present_iff wants_usb_autosuspend_dropin file_exists /etc/modprobe.d/vekrona-usb-autosuspend.conf
  check assert "no stale dGPU udev rule from an earlier install" file_absent /etc/udev/rules.d/70-vekrona-dgpu.rules
  check assert "$VEKRONA_USER in input group" group_member "$VEKRONA_USER" input
  check assert "/dev/uinput exists" file_exists /dev/uinput

  for u in tailscaled nix-daemon.service; do
    check assert "$u enabled" unit_enabled "$u"
    check assert "$u active" unit_active "$u"
  done

  if tailscale_logged_out; then
    warn_check "tailscale operator is $VEKRONA_USER (tailscaled forgets it across restarts until the first login: run 'tailscale up', then ./install.sh 40)" tailscale_operator_is_user
  else
    check assert "tailscale operator is $VEKRONA_USER" tailscale_operator_is_user
  fi
fi

if ran 45-auth; then
  check assert "authselect selects custom/vekrona with its four features" authselect_selection_ok
  for f in system-auth password-auth; do
    check assert "both pam_u2f template lines pinned to pam://vekrona in the profile's $f" vekrona_pam_u2f_lines_ok "/etc/authselect/custom/vekrona/$f" 2
    check assert "the one enabled pam_u2f line pinned to pam://vekrona in /etc/pam.d/$f" vekrona_pam_u2f_lines_ok "/etc/pam.d/$f" 1
  done
  check assert "dankshell-u2f equals the repo file" root_files_equal "$VEKRONA_ROOT/etc/pam.d/dankshell-u2f" /etc/pam.d/dankshell-u2f
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
    check assert "default kernel $default_kver has an initramfs" file_exists "$(initramfs_path_for "$default_kver")"
    while IFS= read -r kver; do
      check assert "initramfs for $kver carries FIDO2 unlock" initramfs_carries_fido2 "$kver"
    done <<<"$initramfs_kvers"
  fi

  warn_check "u2f_keys or fingerprint prints registered for $VEKRONA_USER" user_has_touch_credentials
  check assert "DMS seed enables fingerprint and security key" python3 -c "
import json
d = json.load(open('$VEKRONA_ROOT/config/DankMaterialShell/settings.seed.json'))
assert d.get('enableFprint') is True and d.get('enableU2f') is True and d.get('u2fMode') == 'or'
"
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
  warn_check "stages run from the system copy $VEKRONA_SYSTEM_ROOT (running from $VEKRONA_ROOT; a dev tree needs --no-pull)" \
    eq "$(realpath "$VEKRONA_ROOT")" "$(realpath -m "$VEKRONA_SYSTEM_ROOT")"
  # A dev tree at the legacy path legitimately owns links into it.
  if [[ "$(realpath "$VEKRONA_ROOT")" != "$(realpath -m "$VEKRONA_LEGACY_ROOT")" ]]; then
    legacy_links="$(vekrona_links "${link_dirs[@]}" | while IFS= read -r l; do
      case "$(readlink "$l")" in "$VEKRONA_LEGACY_ROOT"/*) printf '%s ' "$l" ;; esac
    done)"
    check assert "no managed symlink points into the legacy $VEKRONA_LEGACY_ROOT/ (found: ${legacy_links:-none})" eq "$legacy_links" ""
  fi
  check assert "sway config validates" env WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
    sway --unsupported-gpu --validate -c "$HOME/.config/sway/config"
  check assert "sway panel scale drop-in present iff an internal panel is connected" present_iff has_internal_panel file_exists "$SWAY_PANEL_SCALE_DROPIN"
  check assert "system X11 keymap converts to Sway's XKB environment" vekrona-xkb-env
  warn_check "system X11 keymap configured (localectl set-x11-keymap)" bash -c "! vekrona-xkb-env 2>&1 >/dev/null | grep -qF 'no X11 keymap configured'"
  check assert "xremap config validates" xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml"
  check assert "sway keybindings all described" vekrona-keybindings --check
  check assert "vekrona-keybindings --list has workspace 10 bindings" bash -c "vekrona-keybindings --list | grep -qF 'workspace 1…10'"
  check assert "vekrona-keybindings --list has the help binding" bash -c "vekrona-keybindings --list | grep -qF 'Show keybindings help'"
  check assert "dms.service wanted by sway-session.target" file_exists "$HOME/.config/systemd/user/sway-session.target.wants/dms.service"
  check assert "dms.service not wanted by graphical-session.target" file_absent "$HOME/.config/systemd/user/graphical-session.target.wants/dms.service"
  check assert "xremap.service enabled" user_unit_enabled xremap
  check assert "tailscale-systray.service enabled" user_unit_enabled tailscale-systray.service
  check assert "vekrona-errors.service linked" file_exists "$HOME/.config/systemd/user/vekrona-errors.service"
  check assert "vekrona-errors-failed.service linked" file_exists "$HOME/.config/systemd/user/vekrona-errors-failed.service"
  check assert "vekrona-errors.service enabled" user_unit_enabled vekrona-errors
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
  check assert "JetBrainsMono Nerd Font installed" bash -c "fc-list | grep -q 'JetBrainsMono Nerd'"
  check assert "vekrona fontconfig linked" file_exists "$HOME/.config/fontconfig/conf.d/50-vekrona-fonts.conf"
  check assert "fc-match sans-serif -> Atkinson Hyperlegible Next" bash -c "fc-match sans-serif | grep -q 'Atkinson Hyperlegible Next'"
  check assert "fc-match sans-serif (Ukrainian i, U+0456) -> Inter" bash -c "fc-match 'sans-serif:charset=0456' | grep -q Inter"
  check assert "fc-match monospace -> JetBrainsMono Nerd Font" bash -c "fc-match monospace | grep -q 'JetBrainsMono Nerd Font'"
  check assert "gsettings font-name: Atkinson Hyperlegible Next 11" gsettings_eq org.gnome.desktop.interface font-name "Atkinson Hyperlegible Next 11"
  check assert "gsettings document-font-name: Atkinson Hyperlegible Next 11" gsettings_eq org.gnome.desktop.interface document-font-name "Atkinson Hyperlegible Next 11"
  check assert "gsettings monospace-font-name: JetBrainsMono Nerd Font 11" gsettings_eq org.gnome.desktop.interface monospace-font-name "JetBrainsMono Nerd Font 11"
  check assert "DankMaterialShell settings.json present" file_exists "$HOME/.config/DankMaterialShell/settings.json"
  check assert "DMS changelog for the installed version marked seen" file_exists "$HOME/.config/DankMaterialShell/.changelog-$(dms_changelog_version)"
  check assert "DMS settings: lockBeforeSuspend=true, acLockTimeout=300" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('lockBeforeSuspend') is True, d.get('lockBeforeSuspend')
assert d.get('acLockTimeout') == 300, d.get('acLockTimeout')
"
  check assert "DMS settings: fontFamily=Atkinson Hyperlegible Next" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('fontFamily') == 'Atkinson Hyperlegible Next', d.get('fontFamily')
"
  check assert "DMS settings: notificationPopupBodyInvokesAction=true" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('notificationPopupBodyInvokesAction') is True, d.get('notificationPopupBodyInvokesAction')
"

  check assert "vekronaSwayWorkspaces plugin linked" file_exists "$HOME/.config/DankMaterialShell/plugins/vekronaSwayWorkspaces/plugin.json"
  check assert "vekronaSwayWorkspaces plugin enabled" bash -c "jq -e '.vekronaSwayWorkspaces.enabled == true' '$HOME/.config/DankMaterialShell/plugin_settings.json' >/dev/null"
  check assert "vekronaSwayWorkspaces plugin placed in a DankBar widget list" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
bars = d.get('barConfigs', [])
assert any('vekronaSwayWorkspaces' in (bar.get(k) or []) for bar in bars for k in ('leftWidgets', 'centerWidgets', 'rightWidgets'))
"

  check assert "vekronaAgent plugin linked" file_exists "$HOME/.config/DankMaterialShell/plugins/vekronaAgent/plugin.json"
  check assert "vekronaAgent plugin enabled" bash -c "jq -e '.vekronaAgent.enabled == true' '$HOME/.config/DankMaterialShell/plugin_settings.json' >/dev/null"
  check assert "vekronaAgent plugin placed in a DankBar widget list" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
bars = d.get('barConfigs', [])
assert any('vekronaAgent' in (bar.get(k) or []) for bar in bars for k in ('leftWidgets', 'centerWidgets', 'rightWidgets'))
"
  check assert "vekrona-agent --help runs" bash -c "vekrona-agent --help >/dev/null"

  for app_id in "${VEKRONA_X11_FLATPAKS[@]}"; do
    flatpak_installed "$app_id" || continue
    override="$(flatpak override --user --show "$app_id" 2>/dev/null || true)"
    check assert "flatpak x11 override set: $app_id" contains x11 "$override"
  done

  firefox_profiles_ini="$(firefox_profile_root)/profiles.ini"
  for webapp_dir in "$VEKRONA_ROOT"/config/firefox/webapps/*/; do
    webapp="$(basename "$webapp_dir")"
    check assert "$webapp webapp profile registered" grep -q "vekrona-$webapp" "$firefox_profiles_ini"
    check assert "$webapp webapp icon installed" file_exists "$HOME/.local/share/icons/hicolor/scalable/apps/vekrona-$webapp.svg"
    check assert_file_contains "$HOME/.local/share/applications/vekrona-$webapp.desktop" "^Icon=vekrona-$webapp\$"
  done
  check assert "vekrona-theme installed" file_exists "$HOME/.local/bin/vekrona-theme"
  check assert_file_contains "$HOME/.config/gtk-3.0/gtk.css" "^/\\* vekrona-gtk-theme: "
  check assert_file_contains "$HOME/.config/gtk-4.0/gtk.css" "^/\\* vekrona-gtk-theme: "
  check assert "GTK theme is adw-gtk3-dark" gsettings_eq org.gnome.desktop.interface gtk-theme adw-gtk3-dark

  ghostty_theme_dir="/usr/share/ghostty/themes"
  for theme_json in "$VEKRONA_ROOT"/config/dms-themes/*.json; do
    theme_name="$(basename "$theme_json" .json)"
    ghostty_theme_name="$(ghostty_theme_for "$theme_name")"
    check assert "ghostty built-in theme exists: $theme_name -> $ghostty_theme_name" \
      file_exists "$ghostty_theme_dir/$ghostty_theme_name"
  done

  recorded_theme_name="$(cat "$(vekrona_theme_name_file)" 2>/dev/null || true)"
  nonempty() { [[ -n "$1" ]]; }
  check assert "recorded theme name present" nonempty "$recorded_theme_name"
  recorded_ghostty_theme="$(ghostty_theme_for "$recorded_theme_name")"
  check assert "ghostty theme include present" file_exists "$GHOSTTY_THEME_INCLUDE"
  check assert_file_contains "$GHOSTTY_THEME_INCLUDE" "^theme = $recorded_ghostty_theme\$"

  check assert_file_contains "$HOME/.config/ghostty/config" '^config-file = vekrona-theme$'
  check assert "ghostty config validates" ghostty +validate-config

  check assert "DMS matugen Ghostty template enabled" python3 -c "
import json
d = json.load(open('$HOME/.config/DankMaterialShell/settings.json'))
assert d.get('runDmsMatugenTemplates', True) is True
assert d.get('matugenTemplateGhostty', True) is True
"

  check assert "no stale vekrona-gpu.conf from an earlier install (the GPU is chosen at login by vekrona-gpu-env)" file_absent "$HOME/.config/environment.d/vekrona-gpu.conf"
  check assert "vekrona-gpu-env runs" vekrona-gpu-env
  check assert "dms.service declared Environment has no QSG_RHI_BACKEND (Vulkan deadlocks the lock screen)" not_contains 'QSG_RHI_BACKEND' "$(systemctl --user show dms -p Environment 2>/dev/null || true)"
  check assert "systemd --user manager environment has no QSG_RHI_BACKEND (Vulkan deadlocks the lock screen)" not_contains 'QSG_RHI_BACKEND' "$(systemctl --user show-environment 2>/dev/null || true)"

  user_path="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')"
  warn_check "$HOME/.local/bin in systemd user PATH" contains "$HOME/.local/bin" "$user_path"
  warn_check "$HOME/.nix-profile/bin in systemd user PATH" contains "$HOME/.nix-profile/bin" "$user_path"

  check assert "devbox runs" "$HOME/.nix-profile/bin/devbox" version
fi

if ran 55-agents; then
  check assert "repo enabled: $CLAUDE_CODE_REPO_ID" repo_enabled "$CLAUDE_CODE_REPO_ID"
  check assert "repo enabled: $MISE_REPO_ID" repo_enabled "$MISE_REPO_ID"
  check assert "/etc/yum.repos.d/claude-code.repo matches repo" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/claude-code.repo" /etc/yum.repos.d/claude-code.repo
  check assert "/etc/yum.repos.d/mise.repo matches repo" cmp -s "$VEKRONA_ROOT/etc/yum.repos.d/mise.repo" /etc/yum.repos.d/mise.repo
  check assert_repo_key_trusted claude-code
  check assert_repo_key_trusted mise
  for p in "${VEKRONA_AGENT_PKGS[@]}"; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "/etc/mise/config.toml matches repo" cmp -s "$VEKRONA_ROOT/etc/mise/config.toml" /etc/mise/config.toml
  check assert "/etc/profile.d/vekrona-mise.sh matches repo" cmp -s "$VEKRONA_ROOT/etc/profile.d/vekrona-mise.sh" /etc/profile.d/vekrona-mise.sh
  check assert "claude resolves" bash -c "command -v claude >/dev/null"
  for t in "${VEKRONA_AGENT_TOOLS[@]}"; do
    check assert "$t shim present" test -x "$(managed_binary "$t")"
  done
  check assert_tree_root_owned_not_writable "$MISE_SYSTEM_DATA_DIR"
  check assert_tree_root_owned_not_writable "$MISE_SYSTEM_CONFIG_DIR"
  check assert_npm_supports_release_age
  for name in claude "${VEKRONA_AGENT_TOOLS[@]}"; do
    warn_check "no user-local copy shadows $name on PATH" bash -c "[[ ! -e '$HOME/.local/bin/$name' ]]"
  done

  for policy in /etc/claude-code/managed-settings.json /etc/codex/requirements.toml /etc/codex/managed_config.toml /etc/opencode/opencode.json; do
    check assert "$policy is a root-owned regular file, not group/other-writable" root_owned_not_writable_file "$policy"
    check assert "$policy matches repo" cmp -s "$VEKRONA_ROOT$policy" "$policy"
  done

  for f in "$VEKRONA_ROOT/config/environment.d/vekrona.conf" "$VEKRONA_ROOT/etc/profile.d/vekrona-mise.sh"; do
    check assert_file_contains "$f" "$MISE_SYSTEM_SHIMS_DIR"
  done
fi

if ran 60-gaming; then
  check assert "scb is executable" bash -c "[[ -x /usr/local/bin/scb ]]"
  for p in gamescope mangohud gamemode steam python3-vdf; do
    check assert "package installed: $p" pkg_installed "$p"
  done
  check assert "scopebuddy config present" file_exists "$HOME/.config/scopebuddy/scb.conf"

  steam_config_vdf="$HOME/.local/share/Steam/config/config.vdf"
  if [[ -e "$steam_config_vdf" ]]; then
    check assert "Steam Play for all titles enabled (proton_experimental)" python3 -c "
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


with open('$steam_config_vdf') as f:
    data = vdf.load(f)

node = data
for key in ('InstallConfigStore', 'Software', 'Valve', 'Steam', 'CompatToolMapping'):
    node = child(node, key)

zero_key = find_key(node, '0')
assert zero_key is not None, 'no CompatToolMapping entry \"0\"'
entry = node[zero_key]
name_key = find_key(entry, 'name')
assert name_key is not None, 'no name field in CompatToolMapping \"0\"'
assert entry[name_key].lower() == 'proton_experimental', entry[name_key]
"
  else
    warn_check "Steam never launched: launch Steam once, quit it, then run ./install.sh 60" false
  fi
fi

if ran 65-login-manager; then
  dm_target="$(dm_unit_target 2>/dev/null || true)"
  if dm_is_greetd; then
    verify_greetd_active
  elif [[ -n "$dm_target" ]]; then
    log "another display manager enabled ($dm_target); skipping greetd checks, 90a-switch-dm is the migration path"
  else
    die "no display manager enabled"
  fi
fi

if ran 90a-switch-dm || ran 90b-remove; then
  verify_greetd_active
  warn_check "gdm not present or disabled" gdm_absent_or_disabled
  warn_check "secrets service reachable" busctl --user status org.freedesktop.secrets
  for p in omedora hyprland keyd; do
    check assert "package absent: $p" pkg_absent "$p"
  done
  declare -a desktop_pkgs
  read_pkg_list desktop_pkgs vekrona_desktop_pkgs
  for p in "${desktop_pkgs[@]}"; do
    check assert "protected desktop package present: $p" pkg_installed "$p"
  done
  for f in /etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf /etc/systemd/oomd.conf.d/vekrona.conf; do
    check assert "override still present: $f" file_exists "$f"
  done
  check assert "usb autosuspend drop-in present iff not a laptop" present_iff wants_usb_autosuspend_dropin file_exists /etc/modprobe.d/vekrona-usb-autosuspend.conf
fi

log "verify summary: ok=$ok_count warn=$warn_count"
