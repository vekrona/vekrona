# vekrona: personal Fedora + Sway desktop — recipe plan (post-review)

## Context

The user runs Fedora 44 Workstation on a desktop (Ryzen 7950X3D, RTX 4090, Dell AW3225QF 4K 240 Hz QD-OLED) and today uses Omarchy-on-Fedora (omedora COPR, Hyprland, Omarchy's Quickshell shell). They like parts of Omarchy but want their own opinionated setup: **stability** first, **gaming-ready** second, macOS-like keyboard without breaking terminals.

Deliverable: repo `vekrona/vekrona` (built locally in `~/wrk/vekrona`; push is the user's, SSH agent unreachable from this session) with an idempotent staged `install.sh`, all configs, a README recipe. Migrated in place on this machine stage by stage, and smoke-tested in a clean Fedora 44 VM.

Grilled 2026-09-29; three adversarial Opus reviews (system, desktop, installer) applied. Facts verified on this machine or from primary sources unless marked *unverified*.

## Decisions (final, post-review)

| # | Decision | Detail |
|---|---|---|
| 1 | In-place migration + clean-VM smoke test | Sway next to GNOME/Hyprland until cleanup. VM: `virt-install` (installed by `vm/Makefile`) F44 Everything netinstall + kickstart (`autopart --type=btrfs`, `%post` clones repo, NOPASSWD sudo in VM only), runs `install.sh --skip nvidia`, then a headless Sway session check. |
| 2 | NVIDIA: RPM Fusion `akmod-nvidia`, **proprietary** module, GSP off | Stage 10 only: enable `rpmfusion-nonfree-nvidia-driver`; delete `cuda-fedora43.repo`, add `cuda-fedora44.repo` with the Howto/CUDA exclude list; **one transaction** `dnf5 do --action=remove cuda-drivers 'nvidia-driver*' kmod-nvidia-latest-dkms nvidia-kmod-common 'libnvidia-*' nvidia-libXNVCtrl nvidia-modprobe nvidia-persistenced nvidia-settings --action=install akmod-nvidia xorg-x11-drv-nvidia-cuda`; then `dnf upgrade cuda-toolkit`; **synchronous** `akmods --force --kernels "$(uname -r)"`, assert `modinfo -F version nvidia` = 615.x and `/lib/modules/$(uname -r)/extra/nvidia*` exists; then `grubby --update-kernel=ALL --args='nvidia.NVreg_EnableGpuFirmware=0 pcie_aspm=off'` (RPM Fusion's own posttrans already adds `rd.driver.blacklist=nouveau,nova_core modprobe.blacklist=nouveau,nova_core`); assert tokens in `grubby --info=ALL` and `/etc/kernel/cmdline`; assert modprobe options + nvidia-suspend/resume/hibernate enabled; versionlock `akmod-nvidia xorg-x11-drv-nvidia*` **after** install. Post-reboot: `nvidia-smi -q | grep 'GSP Firmware'` = N/A, `/proc/driver/nvidia/version` says "Kernel Module" not "Open", `sudo cat /sys/module/nvidia_drm/parameters/modeset` = Y. |
| 3 | Remapper: **xremap** (`xremap-wlroots`, COPR `blakegardner/xremap`) | Binary `/usr/bin/xremap-wlroots`. `exact_match: true` on every keymap. Caps held → `[Ctrl_L, Alt_L, Super_L]`, tapped → Esc. Cmd layer per app_id exclusion. Key names per xremap (`LeftBrace`, `PageUp`…); `70-verify` runs `xremap-wlroots --validate-config`. User unit `PartOf/After/WantedBy=sway-session.target`, `--watch=config,device`. User in `input` group (README: security trade-off, keyboards readable by user processes; re-login needed). |
| 4 | Terminal: **ghostty** | `super+c=copy_to_clipboard`, `super+v=paste_from_clipboard`; Hyper split binds dropped. Exclusion app_ids `com.mitchellh.ghostty`, `foot`, `org.wezfurlong.wezterm`. Files symlinked individually (DMS writes `~/.config/ghostty/themes/dankcolors`). |
| 5 | Fedora policy: one release behind | F44 until F46 GA (~2027-04). README release-upgrade procedure: manual snapshot → `dnf versionlock clear` → `dnf system-upgrade` → verify → re-lock. `70-verify` warns when a lock's `.fcNN` ≠ `VERSION_ID`. |
| 6 | Output | `output DP-7 mode 3840x2160@240Hz adaptive_sync on scale 1.5`. `WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card` (hide AMD iGPU from wlroots). HDR off. |
| 7 | Input + **Hyper = Ctrl+Alt+Super (Shift removed — review finding: with Shift inside Hyper, Hyper+Shift+X is the same mask as Hyper+X and overwrites it)** | `xkb_layout us,ua`, `xkb_options grp:alts_toggle,shift:both_capslock_cancel`, repeat 40/250, numlock on, flat accel -0.7. All letter binds `bindsym --to-code`. Sway: `set $hyper Mod4+Ctrl+Mod1`; Hyper = focus/launch layer, Hyper+Shift = move/secondary layer. |
| 8 | UI: **DMS on Quickshell**, pinned COPR packages | COPRs `avengemedia/dms` + `avengemedia/danklinux`. Stage 30: `dnf install --from-repo=copr:copr.fedorainfracloud.org:avengemedia:danklinux quickshell` (swap off omedora build; assert `rpm -q --qf '%{vendor}' quickshell` ≠ agaspar) **before** locking `dms quickshell qt6-qtbase qt6-qtdeclarative qt6-qtwayland`. README: Qt lock holds ~44 qt6 packages; `dnf check-upgrade 'qt6-*'` shows what is withheld. `dms.service` drop-in: `[Unit] ConditionEnvironment=XDG_CURRENT_DESKTOP=sway` `PartOf=sway-session.target` `[Service] Environment=QSG_RHI_BACKEND=vulkan` `[Install] WantedBy=sway-session.target` (not graphical-session.target: would start inside Hyprland/GNOME fallbacks and fight for `org.freedesktop.Notifications`). DMS polkit agent is the only agent (`lxqt-policykit` stays installed as a sway-config-fedora dep but is never exec'd). Removed from use (not from disk, sway-config-fedora requires some): waybar, fuzzel, mako, swayosd, swaylock, swayidle, wlsunset, swaybg, cliphist. |
| 9 | Idle | DMS settings: `acMonitorTimeout: 600`, `acLockTimeout: 300`, `acSuspendTimeout: 1800`, `lockBeforeSuspend: true`, `loginctlLockIntegration: true`. logind `InhibitDelayMaxSec=15` (file `vekrona-inhibit-delay.conf`). README: if Quickshell dies while locked, Sway paints red; recovery from TTY: `SWAYSOCK=… WAYLAND_DISPLAY=… dms ipc call lock lock`. |
| 10 | Sleep disabler | `vekrona-caffeine [30m|1h|2h|off]` = `systemd-inhibit --what=sleep --who=vekrona --why=caffeine sleep N` (a deliberate wall-clock duration is the feature, not pacing) + DMS notification; bound Hyper+Shift+c. DMS bar indicator: *unverified* plugin API → TODO.md. |
| 11 | Login: **greetd + tuigreet** | `/etc/greetd/config.toml`: `[terminal] vt = 1`, `[default_session] command = "tuigreet --time --remember --cmd start-sway"`, `user = "greetd"`. tmpfiles `d /var/cache/tuigreet 0755 greetd greetd`. Switch = stage 90a: `systemctl disable gdm && systemctl enable --force greetd`, reboot. |
| 12 | Omarchy parts | Themes (DMS custom JSON + DMS-run matugen templates, verified DMS runs matugen for static themes), launcher/power menu (DMS), screenshot grim+slurp+swappy, recording wf-recorder, keybindings ported to Hyper, clipboard/night/calendar (DMS), caffeine (#10). Wallpaper per theme. Webapps Firefox. Dropped: Chrome webapps, app set, wallpaper cycling. |
| 13 | Themes | Tokyo Night, Catppuccin Mocha, Gruvbox Dark, Nord: `config/dms-themes/<name>.json` + wallpaper. `vekrona-theme <name>` = `dms ipc call settings set customThemeFile <path>` + `dms ipc call wallpaper set <path>`. Nerd font: **vendored** JetBrainsMono Nerd Font TTFs (OFL) → `~/.local/share/fonts/vekrona/`; verify `fc-list | grep -q 'JetBrainsMono Nerd'`. |
| 14 | Webapps | `firefox -CreateProfile "<app> ~/.mozilla/firefox/vekrona-<app>"` (idempotent via profiles.ini check), symlink `user.js` (with `toolkit.legacyUserProfileCustomizations.stylesheets=true`) and `chrome/userChrome.css`; launcher `vekrona-webapp <app>` = `firefox --name vekrona-<app> -P <app> --no-remote --new-window <url>`; `.desktop` with `StartupWMClass`. Apps: YouTube, WhatsApp Web. |
| 15 | Gaming | Steam RPM, gamescope, ScopeBuddy 1.5.0 pinned script, mangohud, gamemode. `scb.conf`: `-f -W 3840 -H 2160 -r 240 --adaptive-sync -e`. |
| 16 | Snapshots | snapper `root` config, `NUMBER_LIMIT=10`, timeline off; actions lines with `-c number`; `snapper-cleanup.timer`. `vekrona-rollback <N>`: mount subvolid=5, `mv root root.old-<ts>`, writable `btrfs subvolume snapshot .snapshots/N/snapshot root`, `mv root.old-*/.snapshots root/.snapshots`, reboot; README warns `/boot` is separate ext4 (pick a kernel present in the snapshot). Rollback exercised for real in the VM (stage 1) and on the host after NVIDIA (stage 3); GRUB `subvol=` edit is look-only (read-only snapshot). TODO.md: nested subvolume for `/var/lib/libvirt/images`. |
| 17 | Repo + mechanism | `~/wrk/vekrona` → `github.com/vekrona/vekrona`. Bash `install.sh [--skip STAGE]... [STAGE...]`; default = all except `90a`/`90b`. `sudo -v` at the start of every stage, no keep-alive loop. Helpers: check → act → assert → die. `symlink`: refuses a non-symlink target (backs it up to `<target>.pre-vekrona` and logs). Symlink **files** wherever apps write into the directory. DMS `settings.json`: seeded from repo when absent, never overwritten (`install.sh --reset-dms-settings` to reseed); verify checks the fixed keys via `dms ipc call settings get`. |
| 18 | Cleanup, two stages, after Sway proven | **90a-switch-dm**: precondition current session is Sway; `dnf mark user NetworkManager polkit wireplumber pipewire xdg-desktop-portal-gtk gnome-keyring gnome-keyring-pam`; disable gdm, enable --force greetd; reboot. **90b-remove**: precondition `systemctl is-active gdm` = inactive and session is Sway (greetd-started); `dnf remove --assumeno` review printed first, then explicit list: `omedora omedora-settings omedora-nerd-fonts hyprland* uwsm xdg-desktop-portal-hyprland keyd hyprsunset plasma-* kf6-* polkit-kde gnome-shell gdm gnome-session* gnome-control-center` + `dnf environment remove workstation-product-environment kde-desktop-environment`, with `--setopt=protected_packages=dnf5,sudo,systemd,systemd-udev,NetworkManager,shim-x64,grub2-efi-x64,setup,selinux-policy-targeted`; drop COPRs omedora-4, alternateved/keyd, wezterm-nightly, phracek/PyCharm; assert `busctl --user status org.freedesktop.secrets`, fonts, `vekrona-*.conf` files present. Re-created overrides use `vekrona-*.conf` filenames: logind inhibit-delay, oomd PSI, faillock deny=10, usbcore autosuspend=-1. |

## Machine facts (verified)

- F44, kernel 7.2.5, dnf5 5.4.4, `dnf5 do` available. Btrfs `root`/`home` on LUKS; `/boot` ext4; fstab+cmdline hard-code `subvol=root`. `/var` inside `root` (491 G used).
- RTX 4090 (`card2`, boot_vga, pci 01:00.0) + AMD iGPU (`card1`). Monitor DP-7. Secure Boot off.
- Driver: cuda repo `nvidia-driver` 595.91.07 (fc43) + `cuda-drivers`, `cuda-toolkit 13.2.2`, `libnvidia-*`, DKMS. `rpmfusion-nonfree-nvidia-driver` disabled (akmod-nvidia 615.71.09). `nvidia-kmod-common` preun strips blacklist tokens.
- sway 1.11 (links `wlroots0.19`), sway-config-fedora 0.4.3 (`start-sway` sources `/etc/sway/environment` and `~/.config/sway/environment`, runs environment.d generator; requires swaybg swayidle swaylock waybar lxqt-policykit grimshot), sway-systemd 0.4.1 (`/etc/sway/config.d/10-systemd-{session,cgroups}.conf`, `/usr/share/sway-systemd/95-xdg-desktop-autostart.conf`, imports `DESKTOP_SESSION XDG_* DISPLAY I3SOCK SWAYSOCK WAYLAND_DISPLAY XCURSOR_*`).
- greetd 0.10.3 (user `greetd`, `Alias=display-manager.service`), tuigreet 0.9.1 (no cache dir shipped).
- quickshell 0.3.0 git from omedora; danklinux has 0.3.1-5; dms 1.6.2 requires `(quickshell or quickshell-git)`; Qt 6.11.2 (44 qt6 pkgs). DMS: `theme` IPC has only toggle/light/dark; `settings set/get`; settings keys `acMonitorTimeout acLockTimeout acSuspendTimeout lockBeforeSuspend loginctlLockIntegration customThemeFile currentThemeName`; runs matugen for static themes; writes `~/.config/ghostty/themes/dankcolors`, `~/.config/gtk-{3,4}.0/dank-colors.css`; ships polkit agent (`DMS_DISABLE_POLKIT`), native clipboard/brightness/gamma/wallpaper/idle/lock (PAM `login` stack).
- xremap-wlroots 0.15.14: binary `xremap-wlroots`, udev rule uinput only, `exact_match` default false, `--validate-config` works.
- Omarchy user units enabled into graphical-session.target (`omarchy-fcitx5`, `omarchy-crash-watch`, `voxtype`…) and `/usr/lib/environment.d/10-omarchy-fcitx.conf` leak into Sway until 90b (README known issue during rollout).
- 1Password autostart via `~/.config/autostart` → needs `95-xdg-desktop-autostart.conf` included.
- Flatpak Electron apps: Discord, Spotify, Obsidian, Signal → `flatpak override --user --nosocket=wayland --socket=x11`.
- VM: libvirt-daemon-kvm + qemu-kvm present, virt-install missing. `start-sway` already sets pixman under kvm.
- GitHub: `vekrona` account exists, repo absent, `gh` unauthenticated, SSH agent unreachable here.

## Repo layout

```
vekrona/
  install.sh            # stage runner: parses --skip/STAGE, sudo -v per stage, runs stages/NN-*.sh in order
  lib/common.sh         # log die run_root ensure_pkg ensure_copr ensure_repo_file ensure_line ensure_symlink ensure_user_unit versionlock_after_install assert_*
  stages/00-repos.sh 10-nvidia.sh 20-snapper.sh 30-packages.sh 40-system.sh 50-user.sh 60-gaming.sh 70-verify.sh 90a-switch-dm.sh 90b-remove.sh
  config/sway/{config,environment,config.d/*.conf}
  config/environment.d/vekrona.conf        # QSG_RHI_BACKEND, WLR_DRM_DEVICES, MOZ_ENABLE_WAYLAND, QT_QPA_PLATFORM
  config/xremap/config.yml
  config/ghostty/config
  config/DankMaterialShell/settings.seed.json
  config/dms-themes/{tokyo-night,catppuccin-mocha,gruvbox-dark,nord}.json  + wallpapers/*.png (generated solid/gradient placeholders)
  config/systemd-user/{xremap.service,dms.service.d/vekrona.conf}
  config/firefox/webapps/{youtube,whatsapp}/{user.js,userChrome.css,app.desktop,url}
  config/scopebuddy/scb.conf  config/mangohud/MangoHud.conf
  etc/greetd/config.toml  etc/tmpfiles.d/vekrona-tuigreet.conf  etc/systemd/logind.conf.d/vekrona-inhibit-delay.conf  etc/systemd/oomd.conf.d/vekrona.conf  etc/security/vekrona-faillock (applied via ensure_line deny=10)  etc/modprobe.d/vekrona-usb-autosuspend.conf  etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions  etc/sway/environment (system: SWAY_EXTRA_ARGS)
  fonts/JetBrainsMonoNerdFont-*.ttf (vendored, OFL)
  bin/vekrona-rollback vekrona-caffeine vekrona-theme vekrona-webapp vekrona-screenshot vekrona-record
  vm/{Makefile,ks.cfg,session-check.sh}
  README.md  TODO.md  LICENSE
```

## Key config content

**Sway config**: `set $hyper Mod4+Ctrl+Mod1`; `include /etc/sway/config.d/*.conf`; `include /usr/share/sway-systemd/95-xdg-desktop-autostart.conf`; `include ~/.config/sway/config.d/*.conf`; output/input per #6/#7. Bindings (all letters `--to-code`): Hyper+Return ghostty · Hyper+Space `dms ipc call spotlight toggle` · Hyper+v clipboard toggle · Hyper+n notifications toggle · Hyper+comma control-center toggle · Hyper+Escape lock lock · Hyper+Backspace powermenu toggle · Hyper+1..9 workspace · Hyper+Shift+1..9 move · Hyper+hjkl/arrows focus · Hyper+Shift+hjkl/arrows move · Hyper+r resize mode · Hyper+f fullscreen · Hyper+w kill · Hyper+t floating toggle · Hyper+e layout toggle split · Hyper+Print `vekrona-screenshot` · Hyper+Shift+Print `vekrona-record` · Hyper+Shift+c `vekrona-caffeine` · Hyper+Shift+n night toggle · Hyper+Shift+t `vekrona-theme next` · XF86Audio*/MonBrightness* → `dms ipc call audio|brightness`. No `exec dms`, no `exec xremap` (units).

**xremap** (`exact_match: true` everywhere):
```yaml
modmap:
  - name: caps-hyper
    remap:
      CapsLock: { held: [Ctrl_L, Alt_L, Super_L], alone: Esc, alone_timeout_millis: 300 }
keymap:
  - name: cmd-layer
    exact_match: true
    application: { not: [com.mitchellh.ghostty, foot, org.wezfurlong.wezterm] }
    remap:
      Super-a: C-a  … (c v x z s f n t w q r l p o) Super-Shift-z: C-Shift-z  Super-Shift-t: C-Shift-t
      Super-Left: Home  Super-Right: End  Super-Up: C-Home  Super-Down: C-End
      Super-Shift-Left: Shift-Home  Super-Shift-Right: Shift-End
      Alt-Left: C-Left  Alt-Right: C-Right  Alt-Shift-Left: C-Shift-Left  Alt-Shift-Right: C-Shift-Right
      Alt-BackSpace: C-BackSpace  Super-BackSpace: [Shift-Home, BackSpace]
      Super-Shift-LeftBrace: C-PageUp  Super-Shift-RightBrace: C-PageDown  Super-Tab: Alt-Tab
  - name: terminal-word-nav
    exact_match: true
    application: { only: [com.mitchellh.ghostty, foot, org.wezfurlong.wezterm] }
    remap: { Alt-Left: C-Left, Alt-Right: C-Right, Alt-BackSpace: C-BackSpace }
```

**Environment**: `~/.config/environment.d/vekrona.conf` (reaches systemd --user and start-sway): `QSG_RHI_BACKEND=vulkan`, `WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card`, `QT_QPA_PLATFORM=wayland`, `MOZ_ENABLE_WAYLAND=1`. `~/.config/sway/environment`: `SWAY_EXTRA_ARGS="--unsupported-gpu"`. `WLR_NO_HARDWARE_CURSORS` documented, off.

**snapper actions** (`vekrona-snapper.actions`): the man-page three lines with `-c number` added to both creates.

**versionlock**: applied by the stage that installs each package: 10 → `akmod-nvidia xorg-x11-drv-nvidia*`; 30 → `sway wlroots0.19 dms quickshell qt6-qtbase qt6-qtdeclarative qt6-qtwayland xremap-wlroots`. Pre-reboot check in 10 and in verify: an nvidia module exists under `/lib/modules/*/extra/` for every installed kernel.

## Rollout (each step gated, confirmed with the user)

1. Skeleton, lib, all stages, configs, VM harness. VM run: kickstart → `install.sh --skip nvidia` exit 0 → `vm/session-check.sh` (headless sway, `dms ipc call lock status`, `xremap-wlroots --validate-config`) → `vekrona-rollback` exercised in VM.
2. Host: stages 00, 20 (snapshot exists), 30 (packages + quickshell swap + locks), 40, 50, 60 — no reboot needed; GDM shows a Sway session.
3. Host: stage 10 NVIDIA, reboot, verify; real `vekrona-rollback` to the pre-10 snapshot and back (roll-forward = rollback to the post-10 snapshot).
4. Host: log into Sway: output 240 Hz VRR, Hyper layer, Cmd layer in Firefox vs ghostty, lock/idle/suspend, DMS features, 4 themes, webapps, 1Password autostart.
5. Host: gaming on one Vulkan title, 30 min.
6. Host: 90a (reboot into greetd), 90b (removal), verify.
7. README finalized; user pushes.

## Verification

`70-verify.sh` receives the effective stage set and asserts per stage: repos/COPRs enabled · driver facts (#2, via sudo/nvidia-smi) · snapper config + cleanup algorithm `number` + a pre/post pair from a `dnf install/remove hello` round-trip · versionlock list ⊇ expected and `.fcNN` matches · `sway --validate` · `xremap-wlroots --validate-config` · `systemctl --user show dms -p Environment` contains vulkan · `getent passwd greetd` · fonts · flatpak overrides · `scb` present · webapp profiles in profiles.ini. Manual: Hyper+w kills a Firefox window (proves exact_match), Ctrl+c in ghostty = SIGINT, Caps tap = Esc, `systemd-inhibit --list` shows caffeine, mangohud frametimes flat under VRR.

## Known issues (README)

Three pre-1.0 layers on NVIDIA; wlroots in-game flicker on NVIDIA (gamescope isolates); actions plugin under offline `system-upgrade` *unverified* (manual snapshot mandated); `input` group trade-off; Omarchy units/IME leak into Sway until 90b; Qt lock withholds updates; red lock screen recovery; `pcie_aspm=off` unexplained; DMS windows share one app_id.
