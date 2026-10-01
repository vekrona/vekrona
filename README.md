# vekrona

Personal Fedora 44 desktop recipe: Sway plus DankMaterialShell (DMS) on
Quickshell. Priorities in order: stability first, gaming-ready second, and a
macOS-style keyboard (Caps Lock as a Hyper key, Cmd-style shortcuts) without
breaking terminal control sequences. Built for one desktop: Ryzen 7950X3D,
RTX 4090, and a Dell AW3225QF (4K, 240 Hz, QD-OLED) on output DP-7.

The baseline for a fresh install is Fedora Linux 44 MINIMAL (the Everything
netinstall with only `@core` selected): text console, no desktop, no display
manager. `./install.sh` takes that baseline all the way to a Sway/DMS desktop
behind a login manager, with a clean Fedora 44 VM used to smoke-test the
whole run first.

This repo also carries the original migration it was built for: turning an
existing Fedora Workstation install (GNOME/GDM, KDE, an Omarchy-on-Fedora
setup with Hyprland) into the same Sway/DMS desktop in place, on that
specific machine, without reinstalling. That migration stays supported
through two extra stages, `90a-switch-dm` and `90b-remove`, which are never
part of the default run and must be named explicitly. See "Migrating an
existing Fedora Workstation" below.

## Layout of the repo

| Path | Contents |
|---|---|
| `install.sh` | stage runner: parses flags and stage names, refreshes sudo, runs `stages/NN-*.sh` in order |
| `lib/common.sh` | shared bash helpers (`log`, `die`, `ensure_*`, `assert_*`), sourced by every stage and by `bin/vekrona-rollback` and `bin/vekrona-snapshot` |
| `lib/display-scale.sh` | derives the internal panel's Sway scale (1 or 2) from its resolution and EDID physical size; `ensure_internal_panel_scale` writes `~/.config/sway/config.d/vekrona-panel-scale.conf` |
| `stages/*.sh` | one script per stage, numbered so the run order is visible in a directory listing |
| `config/` | source of truth for dotfiles; stage `50-user` symlinks these into `$HOME`. Stage `50-user` also generates `~/.config/environment.d/vekrona-gpu.conf` itself, not tracked under `config/`, only when `/dev/dri/vekrona-dgpu` exists (see Known issues) |
| `etc/` | system files installed into `/etc` by `ensure_root_file` |
| `bin/vekrona-*` | the CLI tools; stage `50-user` symlinks the whole directory into `~/.local/bin` |
| `fonts/` | vendored JetBrainsMono Nerd Font (OFL, v3.5.1), symlinked into `~/.local/share/fonts/vekrona` |
| `config/fontconfig/conf.d/50-vekrona-fonts.conf` | fontconfig aliases: `sans-serif`/`system-ui` prefer Atkinson Hyperlegible Next then Inter (Atkinson has no Cyrillic, Inter covers it), `monospace` prefers JetBrainsMono Nerd Font; symlinked into `~/.config/fontconfig/conf.d/` |
| `config/DankMaterialShell/plugins/vekronaSwayWorkspaces/` | DMS DankBar plugin: always shows Sway workspaces 1-5 plus any existing 6-10, replacing the stock workspace switcher (see "The vekronaSwayWorkspaces DankBar plugin" below); stage `50-user` symlinks the whole `plugins/` directory into `~/.config/DankMaterialShell/plugins/` |
| `vm/` | libvirt smoke-test harness: Makefile, kickstart, session, rollback, and login-manager checks |
| `iso/` | installable-ISO tooling: `fetch-netinst.sh` (verified Fedora netinstall download), `build.sh` (mkksiso release/test ISO builder), `qemu-test.sh` (plain-QEMU install-and-boot test of a test ISO) |
| `.github/workflows/iso.yml` | CI: builds the release and test ISOs in a Fedora 44 container, boots the test ISO under QEMU/KVM on the runner, and attaches the release ISO to tagged GitHub releases |
| `docs/PLAN.md` | the design record: decisions, verified machine facts, rollout, verification, known issues |
| `TODO.md` | open follow-ups not yet folded into a stage |

## Install

### Fresh install on Fedora minimal

Prerequisites:

- Fedora Linux 44, installed from the Everything netinstall with only `@core`
  selected: text console, `multi-user.target`, no desktop, no display
  manager.
- Network access.
- Btrfs root subvolume, with `/boot` on its own filesystem. Stage
  `20-snapper` and `bin/vekrona-rollback` assume btrfs and snapper.
- A user account with sudo access. `install.sh` refuses to run as root
  itself; stages call `sudo` where they need it.
- `git`, installed by hand, since no stage can install its own bootstrap
  dependency: `sudo dnf install -y git`.

Commands:

```
git clone https://github.com/vekrona/vekrona ~/wrk/vekrona
cd ~/wrk/vekrona
./install.sh
```

With no arguments, `install.sh` runs the default stage list in this order:
`00-repos 20-snapper 10-nvidia 15-mac 30-packages 40-system 45-auth 50-user 60-gaming 65-login-manager 70-verify`
(on a Mac, `10-nvidia` is skipped; on non-Mac hardware without NVIDIA, both `10-nvidia` and `15-mac` are skipped).
Snapper runs before NVIDIA so a snapshot exists before stage `10-nvidia` touches
the driver. Stage `65-login-manager` runs last, after everything that
installs and configures greetd (`30-packages`, `40-system`) and right before
verify: on a fresh install nothing owns `display-manager.service` yet, so it
enables greetd and switches the default target to `graphical.target`. See
"New default stage: 65-login-manager" below for the exact condition.

Reboot, then log in through the greeter (tuigreet, running `start-sway`).

### Install from ISO

Instead of installing plain Fedora minimal by hand and cloning this repo
yourself, `iso/build.sh` bakes both into a Fedora 44 Everything netinstall
ISO: Anaconda still asks for a disk and a user (btrfs autopart preset), then
a first-boot service clones this repo to the new user's home and runs
`./install.sh` unattended, ending at the same greetd login prompt. See "ISO
and CI" below for how the ISO is built, what first boot does, and how it is
tested.

### Sign-in methods

The installer offers an optional **SIGN-IN METHODS** screen to enroll a security
key (YubiKey or equivalent FIDO2 device) or a USB fingerprint reader. Either
device then works for sudo, polkit, the login greeter, and the lock screen,
with your password always available as a fallback.

**Security key (FIDO2, PIN + touch):** unlocks the disk at boot and signs you in.
- Both touches (LUKS enrollment and PAM registration) happen once, during
  install, and the installer derives a secret for disk unlock that gets stored in
  a `systemd-fido2` token keyslot. After first boot, the key's PIN and a touch
  are needed to unlock the disk; the password alone also works.
- Later, to enroll the key on an already-installed machine, run:
  ```
  pamu2fcfg -N -o pam://vekrona -i pam://vekrona > ~/.config/Yubico/u2f_keys
  sudo systemd-cryptenroll --fido2-device=auto --fido2-with-client-pin=yes /dev/mapper/root
  ```
  then rerun `./install.sh 45` to update crypttab and rebuild the initramfs.
- PAM origin is fixed at `pam://vekrona` so later hostname changes do not break
  key sign-in.

**Fingerprint (USB reader via libfprint):** signs you in but does not unlock the disk.
- A fingerprint reader returns only match/no-match, not a cryptographic secret,
  so it cannot work with LUKS. If you need disk unlock with biometrics, use a
  FIDO2 key with a built-in fingerprint sensor (a "Bio" key); that is out of
  scope here.
- After install, enroll another finger with `fprintd-enroll <finger>`.

**Lock screen:** touch-only (no PIN prompt) to avoid burning through FIDO2 PIN
retries on mistyped patterns. The screen sends its password answer to every
PAM prompt, so a PIN dialog would lock you out after too many wrong answers.

**Password:** always works, regardless of key/fingerprint enrollment.

If you skip the SIGN-IN METHODS screen during install, the machine works exactly as
before: password-only, no optional keys or fingerprint.

### Install on a MacBook (2013–2015)

This targets Intel MacBook Pro models from 2013–2015 (non-T2, MacBookPro11,x and
12,1). MacBook Air models and T2 Macs (2018–2020, Touch ID) are out of scope: T2
Macs need a patched kernel and a Secure Enclave proxy. Everything below is
untested on hardware unless it says otherwise.

**Before install:**
- Update the firmware to the latest macOS version before you wipe the disk
  (recovery holds older firmware).
- Wi-Fi decides what you need on day one:
  - BCM4360 (`14e4:43a0`, MacBookPro11,1 to 11,3) has no in-kernel driver. It
    needs `wl` from RPM Fusion (`akmod-wl` build -63 or later on kernel 7.2+).
    Anaconda cannot load it, so installation and the first boot both need
    Ethernet (a Thunderbolt or USB adapter) or USB tethering. Wi-Fi works only
    after stage 15 has built `wl` and you have rebooted. Stage 15 checks the
    network first and dies with a message naming Ethernet or tethering if there
    is none.
  - BCM43602 (`14e4:43ba`, MacBookPro11,4, 11,5 and 12,1) works out of the box
    with `brcmfmac`. Stage 15 installs
    `etc/systemd/system-sleep/vekrona-brcmfmac-resume`, which reloads the driver after resume.
- The machine has no built-in fingerprint reader. A USB reader supported by
  libfprint (check its lsusb ID at
  https://fprint.freedesktop.org/supported-devices.html) works for sudo and
  login, never for disk unlock. A security key (FIDO2) can unlock the disk.

**Boot:** hold Option at power-on and pick "EFI Boot" to boot the install media.

**What stage 15-mac does:**
- Builds the Broadcom `wl` Wi-Fi module when a BCM4360 is present and fails
  loudly if the module is missing for the target kernel.
- Sets `apple-gmux force_igd=y` on dual-GPU models, so the Intel GPU is primary.
  The proprietary NVIDIA driver is skipped on Macs: the GT 750M needs the 470
  legacy driver, which does not build on kernel 7.x, so nouveau binds instead
  (stage 10-nvidia does not run).
- Builds the FaceTime HD camera driver from a pinned patjak/facetimehd 0.7.2
  source as DKMS, and extracts the camera firmware from Apple's download. Both
  downloads are verified by sha256.
- Installs Intel VA acceleration (`libva-intel-driver`).
- On MacBookPro12,1, adds the audio quirk `snd_hda_intel model=mbp11`.

**Display and input:** `lib/display-scale.sh` reads the internal panel's
resolution and physical size from DRM and its EDID, and writes
`~/.config/sway/config.d/vekrona-panel-scale.conf` with scale 2 when the panel
is at least 192 DPI, otherwise scale 1. The touchpad uses tap-to-click,
natural scroll and `click_method clickfinger`. The keyboard backlight keys call
`brightnessctl --device='smc::kbd_backlight'`.

**Known gaps:** fan control, suspend/resume and the items in the checklist below
are open in TODO.md.

#### Real MacBook checklist

Run after the install and report what fails:

1. `cat /sys/class/dmi/id/product_name` and `lspci -nn -d 14e4:` (Wi-Fi
   `43a0` or `43ba`, camera `1570`).
2. `./install.sh --list` shows `15-mac` and not `10-nvidia`.
3. Wi-Fi connects, then still works after a suspend and resume.
4. After a kernel update and before rebooting, run `modinfo -k <new kernel> wl`
   (BCM4360 only) and `modinfo -k <new kernel> facetimehd`.
5. The Intel GPU is primary, and the dGPU is powered down:
   `sudo cat /sys/kernel/debug/vgaswitcheroo/switch`.
6. `v4l2-ctl --list-devices` lists the FaceTime HD camera, and an app shows
   a picture.
7. Audio plays and the microphone records (MacBookPro12,1 quirk).
8. The fn keys work: volume, brightness, keyboard backlight.
9. The display scale is right (2 on Retina) and the touchpad clicks with
   one and two fingers.
10. `sensors` under load: fans spin up and temperatures stay sane.
11. Hold Option at power-on: the picker lists the Fedora entry.
12. With a USB fingerprint reader: `fprintd-enroll`, then `sudo` accepts a
    finger.
13. Battery: the screen dims and the machine suspends at the idle timeouts.

### Migrating an existing Fedora Workstation

This is the original use case this repo was built for: turning an existing
Fedora Workstation machine (GNOME/GDM, KDE, an Omarchy-on-Fedora setup with
Hyprland) into the same Sway/DMS desktop in place, without reinstalling. It
runs the same default stage list first (Sway ends up living next to GNOME and
Hyprland during this), then two extra stages that are never part of the
default run:

- `90a-switch-dm` disables gdm and enables greetd (through the same shared
  helper `65-login-manager` uses), unconditionally, then asks for a reboot.
  Its precondition is that the current session is Sway, reached either by
  logging in through GDM's Sway entry or by running `start-sway` from a text
  console.
- `90b-remove`, run after that reboot from the greetd-started Sway session,
  reviews and removes the leftover Omarchy/Hyprland/KDE/GNOME packages.

`docs/PLAN.md` has the full rationale and the gated rollout used the one time
this machine was actually migrated; see "Rollout order" below for the
step-by-step version.

`90b-remove` is proven by its reviewed dry runs, not by an executed removal.
It was rehearsed in a VM prepared with a GNOME, GDM, KDE Plasma, and
Workstation environment fixture, all the way up to its final confirmation
prompt: the stage's own `--assumeno` review showed an explicit removal of
206 packages and an `autoremove` of 4 more, none of them from the verified
vekrona base and none from the vekrona package list. The rehearsal stopped
there; the removal itself was not executed, because the test environment's
permission guard refused the confirmation keystroke. Two things could not be
rehearsed in that VM at all, because the VM fixture never had them
installed: the Omarchy, omedora, and Hyprland packages that the real machine
carries, and the `fedora-release-identity-workstation` to
`fedora-release-identity-basic` identity swap that only runs when
`fedora-release-identity-workstation` is installed. Before running
`90b-remove` for real: take a snapshot first (`vekrona-snapshot`), and read
the reviewed removal and autoremove lists it prints before typing `yes`.

Separately, the two-step review-confirm-execute flow itself (explicit
removal, then `autoremove`) was executed for real, not just reviewed, against
a small KDE Plasma fixture on a minimal Fedora VM, to prove the confirmation
and execution path actually works end to end. That fixture is much smaller
than the real machine's Workstation-plus-Omarchy install, so it does not
stand in for the 206/4-package rehearsal above; it only proves the mechanism,
not the real machine's package set.

### New default stage: 65-login-manager

`stages/65-login-manager.sh` and `stages/90a-switch-dm.sh` share one helper
in `lib/common.sh`, `enable_greetd_login_manager`, that enables greetd, sets
`graphical.target`, and asserts both plus that `display-manager.service`
points to greetd. The difference between the two stages is the precondition:

- `65-login-manager` only acts when **no** display manager is enabled at all
  (`/etc/systemd/system/display-manager.service` absent), which is the state
  of a fresh minimal install and the idempotent no-op state once greetd is
  already the one enabled. If some other display manager owns
  `display-manager.service` (gdm, sddm, lightdm, the state of an
  unmigrated Workstation install), it logs that and leaves it alone;
  `90a-switch-dm` is the migration path for that case.
- `90a-switch-dm` has no such guard: migrating a Workstation machine means
  explicitly disabling gdm and switching to greetd.

`70-verify.sh` shares the same three assertions between the two stages
instead of duplicating them, gated the same way: under `65-login-manager` it
only checks greetd when `display-manager.service` already points to it, and
asserts nothing about greetd when another display manager is in charge.

### Stage semantics

- Name a stage by its number prefix, its name suffix, or its full name: `./install.sh 30`, `./install.sh packages`, and `./install.sh 30-packages` all run the same stage.
- `--skip STAGE` drops one stage from the run, and also drops it from the set that `70-verify` checks.
- Pass explicit stage names to run a subset, for example `./install.sh 10 30` (used later to re-lock package versions after a Fedora upgrade, see Update policy below).
- `90a-switch-dm` and `90b-remove` never run by default; name them explicitly, e.g. `./install.sh 90a-switch-dm`.
- `--reset-dms-settings` overwrites `~/.config/DankMaterialShell/settings.json` from the seed file. Without it, an existing `settings.json` is left alone on every re-run, so DMS settings changed by hand survive a re-run of stage `50-user`. This flag only resets `settings.json`. The separate DMS session file, `~/.local/state/DankMaterialShell/session.json`, is seeded whenever it is absent regardless of this flag, and is never overwritten once it exists, even by `--reset-dms-settings`.
- Each stage starts with `sudo -v`, so expect one password prompt per stage. There is no background loop refreshing the sudo timestamp mid-stage, so a long stage can prompt again partway through.
- Every stage is written to be idempotent: the `ensure_*` helpers in `lib/common.sh` check the current state before changing anything, so re-running `./install.sh` after a partial or failed run only touches what is still missing.
- `ensure_symlink` never overwrites a real file silently. If the symlink target already exists and is not itself a symlink, it gets moved to `<target>.pre-vekrona` first. If that backup path is already taken, the stage fails instead of picking a second name, because a second collision at the same path usually means an earlier conflict was never resolved by hand.

### Rollout order

`docs/PLAN.md` prescribes a specific, gated rollout for migrating a machine for
the first time, each step confirmed before moving to the next:

1. VM first. `make -C vm create`, then `make -C vm test`, which runs `./install.sh --skip 10-nvidia` inside the VM, a headless Sway session check, a real snapshot/rollback round trip, and (post-reboot) the fresh-install login manager check (see VM smoke test below).
2. Host, no reboot needed: stages `00`, `20`, `30`, `40`, `50`, `60` (`65-login-manager` is skipped here on purpose: gdm is still enabled on a Workstation machine at this point, so it would only log and leave it alone; running it explicitly adds nothing until the cleanup step).
3. Host, NVIDIA: stage `10`, reboot, `./install.sh 70`, then a real `vekrona-rollback` to the pre-`10` snapshot and back.
4. Host, Sway validation: log into the Sway session (through GDM's Sway entry, or `start-sway` from a text console) and check the 240 Hz output, the Hyper layer, the Cmd layer in a browser versus a terminal, lock/idle/suspend, DMS features, all four themes, the webapps, and autostart apps such as 1Password.
5. Host, gaming: one Vulkan title through Steam with the `scb --` launch option, for about 30 minutes.
6. Host, cleanup: `90a-switch-dm`, reboot, then `90b-remove`, then `./install.sh 70` again.
7. Finish the README and push.

## Keyboard

Caps Lock becomes Hyper (Ctrl+Alt+Super) when held, and Esc when tapped alone
within 300 ms. This comes from the `caps-hyper` modmap in
`config/xremap/config.yml`, run by xremap-wlroots as a user systemd service
(`config/systemd-user/xremap.service`). It requires the user to be in the
`input` group so xremap-wlroots can read raw keyboard events (see Known
issues).

Sway (`config/sway/config`) defines `$hyper` as `Mod4+Ctrl+Mod1` and binds the
launch/focus layer on it:

| Binding | Action |
|---|---|
| Hyper+Return | launch ghostty |
| Hyper+Space | `dms ipc call spotlight toggle` |
| Hyper+v | `dms ipc call clipboard toggle` |
| Hyper+n | `dms ipc call notifications toggle` |
| Hyper+comma | `dms ipc call control-center toggle` |
| Hyper+Escape | `dms ipc call lock lock` |
| Hyper+BackSpace | `dms ipc call powermenu toggle` |
| Hyper+slash | show the keybindings help panel (`vekrona-keybindings`) |
| Hyper+1..9, Hyper+0 | switch to workspace 1 through 10 |
| Hyper+h/j/k/l, arrow keys | focus left/down/up/right |
| Hyper+r | enter resize mode (h/j/k/l or arrows resize, Return or Escape exits) |
| Hyper+f | toggle fullscreen |
| Hyper+w | kill the focused window |
| Hyper+t | toggle floating |
| Hyper+e | toggle split layout |
| Hyper+- | split horizontally: the next window opens below the focused one |
| Hyper+\\ | split vertically: the next window opens to the right of the focused one |
| Hyper+= | go to a new workspace (the first empty one, `vekrona-workspace-new`) |
| Hyper+Shift+= | move the focused window to a new workspace and follow it |
| Hyper+Print | `vekrona-screenshot` |
| Hyper+Shift+c | `vekrona-caffeine` |
| Hyper+Shift+n | `dms ipc call night toggle` |
| Hyper+Shift+t | `vekrona-theme next` |
| XF86Audio* / XF86MonBrightness* | `dms ipc call audio ...` / `dms ipc call brightness ...` |

Hyper+Shift is the second layer, used for moving things instead of focusing
them:

| Binding | Action |
|---|---|
| Hyper+Shift+1..9, Hyper+Shift+0 | move the focused container to workspace 1 through 10 |
| Hyper+Shift+h/j/k/l, arrow keys | move the focused container left/down/up/right |
| Hyper+Shift+Print | `vekrona-record` |

Shift is not folded into the Hyper mask itself: Hyper is exactly
Ctrl+Alt+Super, and Hyper+Shift is a separate binding on top of it. Putting
Shift inside the Hyper mask would make Hyper+Shift+X carry the same modifier
mask as some other Hyper+X binding and silently overwrite it.

### Keybindings help panel

`bin/vekrona-keybindings`, bound to Hyper+slash, is an Omarchy-style help
panel: it reads `~/.config/sway/config` and its `include`s directly (Sway
itself doesn't expand includes in `swaymsg -t get_config`), pairs every
`bindsym` with the `#: <description>` comment line placed directly above it
in the config, and renders them in a `rofi -dmenu` list styled from the
active vekrona/DMS theme (`~/.local/state/vekrona/active-theme.json`).
Alternative chords (`h` / `Left`) and the workspace 1..10 bindings are
collapsed into single rows; picking a Sway row runs its command through
`swaymsg`. It also lists the xremap Caps Lock and Cmd-layer remaps
(`config/xremap/config.yml`) and the `Alt+Alt` layout toggle, both
informational only. `vekrona-keybindings --list` prints the same rows as
plain text and `--check` fails if any `bindsym` in the Sway config is
missing its `#:` description; `stages/70-verify.sh` runs `--check` and
greps `--list` for the workspace-10 and help rows. Every `bindsym` in
`config/sway/config`, including the `mode "resize"` block and the XF86
media keys, must carry a `#:` description line directly above it, or the
panel refuses to run.

### The Cmd layer (xremap)

Outside three terminal app_ids, `com.mitchellh.ghostty`, `foot`, and
`org.wezfurlong.wezterm`, the `cmd-layer` keymap in
`config/xremap/config.yml` turns Super into a macOS-style Cmd modifier. Every
letter, Cmd+a through Cmd+z, sends the same letter under Ctrl instead:

| Cmd shortcut | Sends | Cmd shortcut | Sends |
|---|---|---|---|
| Cmd+Shift+z | Ctrl+Shift+z | Cmd+Shift+t | Ctrl+Shift+t |
| Cmd+Shift+n | Ctrl+Shift+n | Cmd+Shift+p | Ctrl+Shift+p |
| Cmd+Shift+f | Ctrl+Shift+f | Cmd+Shift+g | Ctrl+Shift+g |
| Cmd+Shift+r | Ctrl+Shift+r | Cmd+Shift+w | Ctrl+Shift+w |
| Cmd+Left | Home | Cmd+Right | End |
| Cmd+Up | Ctrl+Home | Cmd+Down | Ctrl+End |
| Cmd+Shift+Left | Shift+Home | Cmd+Shift+Right | Shift+End |
| Cmd+Shift+Up | Ctrl+Shift+Home | Cmd+Shift+Down | Ctrl+Shift+End |
| Cmd+Backspace | Shift+Home, then Backspace | Alt+Backspace | Ctrl+Backspace |
| Alt+Left | Ctrl+Left | Alt+Right | Ctrl+Right |
| Alt+Shift+Left | Ctrl+Shift+Left | Alt+Shift+Right | Ctrl+Shift+Right |
| Cmd+Tab | Alt+Tab | Cmd+Shift+Tab | Alt+Shift+Tab |
| Cmd+Shift+[ | Ctrl+PageUp | Cmd+Shift+] | Ctrl+PageDown |
| Cmd+comma | Ctrl+comma | | |

Inside those three terminals, the Cmd layer is off entirely so Ctrl still
reaches the shell for things like Ctrl+C. Only Alt+Left/Right is remapped
there, to Ctrl+Left/Right, which readline (`backward-word`/`forward-word`)
already understands. Alt+Backspace is left unmapped in the terminal: Ghostty
sends it as ESC DEL (`\e\x7f`), which bash's readline already binds to
`backward-kill-word`, deleting the previous word. Remapping it to
Ctrl+Backspace like the Cmd layer does for GUI apps does not work here:
Ghostty encodes Ctrl+Backspace as a bare Ctrl-H byte (`^H`, 0x08), and
readline binds plain Ctrl-H to `backward-delete-char`, so it would delete one
character instead of a word. Copy and paste in ghostty come from ghostty's
own keybinds instead (`config/ghostty/config`: `super+c=copy_to_clipboard`,
`super+v=paste_from_clipboard`), not from xremap.

`xkb_options grp:alts_toggle` in `config/sway/config` toggles between the two
configured keyboard layouts, `us` and `ua`, by pressing Left Alt and Right Alt
together.

## Daily operations

Theme (applies the DMS color scheme, the terminal colors, and a matching 4K
wallpaper, and remembers the current theme in `~/.local/state/vekrona/theme`
so `next` cycles correctly; the four themes are `tokyo-night`,
`catppuccin-mocha`, `gruvbox-dark`, `nord`, and their wallpapers are
generated solid/gradient placeholders, swap them for real images if wanted).

Terminal colors come from Ghostty's own built-in themes, not from DMS. Each
vekrona theme maps to one Ghostty built-in theme, in the single mapping
`ghostty_theme_for` in `lib/common.sh` that `vekrona-theme`,
`stages/50-user.sh` and `stages/70-verify.sh` all read; a vekrona theme with
no entry in that mapping is a hard, immediate error, never a silent
fallback. `vekrona-theme` writes the mapped name into
`~/.config/ghostty/vekrona-theme` (a single `theme = <name>` line, written
atomically), which `config/ghostty/config` pulls in with `config-file =
vekrona-theme`, and then reloads any already-running Ghostty windows over
Ghostty's own D-Bus `org.gtk.Actions` interface (the same `reload-config`
action its default `ctrl+shift+,` keybind runs), so open terminals update
immediately without the user doing anything. `stages/50-user.sh` writes
this same include for the seeded default theme on a fresh install, or for
whichever theme is recorded in `~/.local/state/vekrona/theme` on an
existing one, so a terminal opened in the very first session already has
the right colors: it does not depend on DMS at all.

DMS and GTK application colors are a separate path and still come from DMS.
The theme content lives in `~/.local/state/vekrona/active-theme.json`,
which `customThemeFile` in the DMS settings seed points at from the first
session onward, so DMS watches that one file and reloads it on every
write; the script writes the new theme into it, then waits for DMS to
confirm the new colors (via `inotifywait` on the ghostty theme file DMS
still generates as a side effect, so it needs `inotify-tools`) and exits
non-zero with a clear message if the theme did not take within the wait,
without retrying or restarting the shell itself. DMS seeds the wallpaper
for the first session from `~/.local/state/DankMaterialShell/session.json`,
so it shows correctly without any `vekrona-theme` call. The DMS colors for
that very first session are not guaranteed: DMS has an internal startup
race between checking whether `matugen` is available and loading the
custom theme file, and when it loses that race it does not retry, so GTK
application colors can stay at GTK defaults until the first
`vekrona-theme <name>` call. No event exists to reliably wait on for that
race from outside DMS, so this is not automated. The terminal no longer has
this problem: Ghostty reads its colors from its own built-in themes, so
they are correct from the first session, with no DMS involvement.

That startup race is also why DMS's matugen template switches,
`runDmsMatugenTemplates` and `matugenTemplateGhostty` in the settings seed,
must stay enabled: they are what makes DMS regenerate the Ghostty color
files at all once it wins the race, and stage `50-user` and stage `70-verify`
both assert they are `true` (the seed omits them, so DMS's own default of
`true` applies; the assertion catches anyone turning them off by hand).

```
vekrona-theme <name>
vekrona-theme next
vekrona-theme list
```

Caffeine (a fixed wall-clock duration is the point, not something to work
around): `vekrona-caffeine` starts a transient systemd user unit
(`systemd-run --user --unit=vekrona-caffeine`) that wraps `systemd-inhibit
--what=sleep` for the given duration, and sends a desktop notification on
start and stop; also bound to Hyper+Shift+c.

```
vekrona-caffeine 30m
vekrona-caffeine 1h
vekrona-caffeine 2h
vekrona-caffeine status
vekrona-caffeine off
vekrona-caffeine        # no argument: stops it if running, else starts it for 1h
```

Screenshot and recording:

```
vekrona-screenshot area     # grim + slurp region capture, opens in swappy, saved to ~/Pictures/Screenshots
vekrona-screenshot output   # full output, same pipeline
vekrona-record              # slurp region select, systemd-run transient user unit toggle, saved to ~/Videos/Recordings
```

Webapps (each opens a dedicated Firefox profile and window, set up by stage
`50-user` from `config/firefox/webapps/<app>/`):

```
vekrona-webapp youtube
vekrona-webapp whatsapp
```

Snapshots:

```
vekrona-snapshot "before X"
```

Wraps `sudo snapper -c root create -p -c number -d "<description>"`; the `-p`
flag prints the new snapshot's number. Every dnf transaction also gets an
automatic pre/post snapshot pair from the actions plugin installed by stage
`20-snapper`.

Rollback:

```
sudo vekrona-rollback <N>
```

`vekrona-rollback` self-elevates through sudo if not already root. It mounts
the top-level btrfs subvolume (`subvolid=5`), snapshots
`.snapshots/<N>/snapshot` as a writable `root.vekrona-new`, renames the live
`root` subvolume to `root.old-<timestamp>`, promotes `root.vekrona-new` to
`root`, and moves the old root's `.snapshots` across so the restored root
keeps its own snapshot history. It then writes a marker file,
`/.vekrona-rolled-back-from-<N>`, so a later check can confirm a rollback
happened. It asks for confirmation unless run with `--yes`, and refuses to
prompt at all when it has no controlling tty, so a non-interactive caller
(such as the VM test harness) must pass `--yes`. Before that, it warns about
every non-rescue kernel in `/boot` that has no matching
`/lib/modules/<kernel>` directory inside the target snapshot. `/boot` is a
separate ext4 filesystem and is never touched by a rollback, so rolling back
to an old snapshot can leave a root whose kernel modules do not match what is
actually in `/boot`; check that warning before rebooting. The script does not
reboot for you; run `systemctl reboot` afterward to boot into the restored
root.

To look at a snapshot without committing to it: at the GRUB menu, press `e`
on the boot entry, change `subvol=root` on the kernel command line to
`subvol=/.snapshots/<N>/snapshot`, then boot it (Ctrl+X or F10). The snapshot
itself is read-only, so this boots into it for inspection without writing
anything, and the edit is not saved, so the next normal boot is unaffected.

Verifying a run:

```
./install.sh 70
```

Runs the assertions in `stages/70-verify.sh`. Run together with other
stages, it checks only the stages that ran in that same invocation. Run
alone, as above, it instead checks the full default stage set (minus
anything passed to `--skip`), so a bare `./install.sh 70` re-verifies
everything without re-running any stage.

Steam launch option, wraps a game with ScopeBuddy using
`config/scopebuddy/scb.conf` (`-f -W 3840 -H 2160 -r 240 --adaptive-sync -e`):

```
scb -- %command%
```

MangoHud toggle in-game: Shift_R+F12 (`config/mangohud/MangoHud.conf`,
`toggle_hud=Shift_R+F12`).

## The vekronaSwayWorkspaces DankBar plugin

Stock DMS pads its workspace switcher to only 3 slots and otherwise shows
whatever Sway currently reports, which deletes an empty workspace as soon as
you focus away from it. `config/DankMaterialShell/plugins/vekronaSwayWorkspaces/`
is a DMS DankBar widget plugin that instead always shows workspaces 1-5, even
empty, plus any workspace 6-10 that currently exists. Click a pill to switch
(`workspace number N` over the Sway IPC socket via `Quickshell.I3`), scroll
over the widget to step through the shown workspaces. Focused, occupied
(has a window), and urgent workspaces are colored using the same `Theme`
tokens (`Theme.primary`/`Theme.secondary`/`Theme.error`) as the stock widget.

Stage `50-user` symlinks the plugin directory into
`~/.config/DankMaterialShell/plugins/`, enables it in
`~/.config/DankMaterialShell/plugin_settings.json`, and replaces
`workspaceSwitcher` with `vekronaSwayWorkspaces` in place in any
`barConfigs[].{left,center,right}Widgets` list that still names the stock
widget, without touching any other bar customization; `settings.seed.json`
already ships `vekronaSwayWorkspaces` in place of the stock widget for a
fresh install. `70-verify` checks the plugin is linked, enabled, and placed
in a bar widget list.

## Update policy

Stay one Fedora release behind: this machine runs F44 until F46 reaches GA.
Staying a release behind gives the NVIDIA driver, Sway/wlroots, and DMS/Qt
time to catch up before this machine takes the upgrade.

The versionlocked set, applied by the stage that installs each package and
recorded in `/etc/dnf/versionlock.toml`:

- Stage `30-packages` locks `sway`, the wlroots package providing the libwlroots soname the installed `sway` links against, `dms`, `quickshell`, `qt6-qtbase`, `qt6-qtdeclarative`, `qt6-qtwayland`, `xremap-wlroots`, the whole compositor and shell stack, so a routine `dnf upgrade` cannot pull one of them out from under versions that were actually tested together.
- Stage `10-nvidia` locks `akmod-nvidia` and every installed `xorg-x11-drv-nvidia*` package, so a routine upgrade cannot install a newer proprietary driver against an untested kernel.

`stages/70-verify.sh` warns when a lock's `.fcNN` suffix no longer matches the
running Fedora version, which is the signal that a lock is now holding back
more than intended.

Release upgrade procedure:

1. Smoke-test the new release in the VM first: bump `FEDORA_RELEASE` in `vm/Makefile`, then run `make -C vm destroy`, `make -C vm create` and `make -C vm test` (see VM smoke test below).
2. Upgrade the host:

```
vekrona-snapshot "before F<N> upgrade"
sudo dnf versionlock clear
sudo dnf system-upgrade download --releasever=<N>
sudo dnf system-upgrade reboot
./install.sh 70
./install.sh 10 30
```

Clearing the lock before the upgrade lets dnf actually move the locked
packages forward with everything else. `./install.sh 70` after the reboot
checks the result; `./install.sh 10 30` re-applies the two locked sets
against whatever versions the new release installed.

The Qt lock alone withholds roughly 44 `qt6-*` package updates on an
otherwise fully-updated system. Check what is being withheld with:

```
dnf check-upgrade 'qt6-*'
```

To upgrade one locked package on purpose, outside a release upgrade: snapshot
first, delete just that lock, upgrade, test that nothing broke, then re-lock
it by re-running the stage that owns it (`30-packages` for the shell stack,
`10-nvidia` for the driver):

```
vekrona-snapshot "before qt6-qtbase upgrade"
sudo dnf versionlock delete qt6-qtbase
sudo dnf upgrade qt6-qtbase
./install.sh 30
```

## Known issues and trade-offs

- Sway/wlroots, Quickshell, and DMS are all pre-1.0 software, stacked on top of each other and on top of the proprietary NVIDIA driver. Snapshot before touching any of them.
- wlroots can flicker in fullscreen games under NVIDIA. Running a game through `scb` (gamescope) isolates it from wlroots' own compositing and works around this.
- ScopeBuddy 1.5.0 sets `SCB_STEAMARGIGNORE=1` by default, which makes it ignore the `-e` flag configured in `scb.conf`'s `SCB_GAMESCOPE_ARGS` unless that default is overridden. Check ScopeBuddy's own behavior before assuming `-e` is doing anything.
- The user is in the `input` group so xremap-wlroots can read raw keyboard events. Any process running as that user can read raw input from every input device on the system, not only the keyboard; a re-login is needed after the group is added.
- If DMS crashes while the screen is locked, Sway paints the screen red instead of showing a lock UI. Recover from a text console: find the locked session's socket paths under `/run/user/$(id -u)/` (`ls /run/user/$(id -u)/sway-ipc.*` for `SWAYSOCK`, and the matching `WAYLAND_DISPLAY`), then run `SWAYSOCK=<path> WAYLAND_DISPLAY=<display> dms ipc call lock lock`.
- A different, worse symptom: if `QSG_RHI_BACKEND=vulkan` is in effect on a machine whose Vulkan is software (Mesa lavapipe, not a real GPU driver), the very first frame of the session lock screen can deadlock inside Qt's Vulkan RHI backend. DMS does not crash and Sway does not paint red; instead the whole Quickshell process freezes solid: the lock screen's clock stops advancing, every `dms ipc call` hangs instead of returning, and a PAM helper process it spawned on lock is left as a zombie, never reaped. Neither the documented red-screen recovery above nor `systemctl --user restart dms` gets you out of this: the IPC call just queues behind the same stuck thread, and a freshly restarted `dms.service` re-acquires the lock and freezes again within seconds while the session is still marked locked. The only recovery found is a reboot. This is why `QSG_RHI_BACKEND=vulkan` is now set only through the hardware-conditional `vekrona-gpu.conf` (see "Layout of the repo" and `docs/PLAN.md` decision #6), gated on `/dev/dri/vekrona-dgpu`, and is never set at all on a machine without that device. Proven in the `vekrona-rehearsal` VM (no dGPU, software Vulkan) on 2026-09-29: forcing `QSG_RHI_BACKEND=vulkan` reproduced the freeze on both an idle-triggered lock and a manual IPC lock; `opengl`, `software`, and Qt's unset default (which resolves to OpenGL on this stack) all locked and unlocked correctly under the same software rendering. Lock and unlock under `QSG_RHI_BACKEND=vulkan` on the real machine, which has the actual RTX 4090 and a real Vulkan driver rather than software rendering, is UNTESTED and must be tested there before relying on it: lock by the Hyper+Escape keybinding, hold a few minutes, unlock; lock by `dms ipc call lock lock`, hold a few minutes, unlock; let the idle timeout lock it on its own, hold a few minutes, unlock. Only rely on the dGPU branch once all three pass on that machine.
- Units and IME state left over from Omarchy, `omarchy-fcitx5`, `omarchy-crash-watch`, and others, plus `/usr/lib/environment.d/10-omarchy-fcitx.conf`, keep running inside Sway until stage `90b-remove` actually removes the omedora packages that own them.
- `90b-remove` no longer removes `kf6-*` explicitly, because `kf6-kimageformats` is a dependency of the Fedora wallpaper package that `sway-config-fedora` needs; KDE framework libraries are removed only as orphans, once nothing else needs them, by the stage's own `autoremove`. The desktop package list (`VEKRONA_DESKTOP_PKGS` in `lib/common.sh`, the packages this desktop actually depends on: NetworkManager, portals, Sway and its stack, DMS, gaming, fonts) is also passed to dnf as a protected package set on every removal and `autoremove` command the stage runs, so a future collision fails the stage instead of silently taking Sway out with it. Not every package vekrona installs is on that list and protected this way: `snapper`, `libdnf5-plugin-actions`, and the NVIDIA packages installed by stage `10-nvidia` (`akmod-nvidia`, `xorg-x11-drv-nvidia-cuda`, and so on) are not in `VEKRONA_DESKTOP_PKGS`, so `90b-remove` does not protect them from its own explicit removal or `autoremove`.
- `90b-remove` no longer runs `dnf environment remove workstation-product-environment kde-desktop-environment`. A rehearsal in a VM built like the real machine showed that command taking 661 packages, 23 of which belonged to the verified vekrona base: CPU/GPU/Wi-Fi/audio firmware, filesystem tools (`dosfstools`, `exfatprogs`, `ntfs-3g`), and media libraries. The cause is that the Workstation and KDE environments bundle groups such as Hardware Support, Multimedia, Fonts, and Printing Support, and removing the environment removes every group in it, protected packages or not. `90b-remove` now removes only the packages named in its explicit list plus whatever `autoremove` finds orphaned afterward. This means applications that were installed as members of the old GNOME or KDE groups (GNOME's own apps, LibreOffice, and so on) stay installed after `90b-remove`; nothing currently prunes them.
- `pcie_aspm=off` is set as a kernel argument by stage `10-nvidia` without a recorded reason. Revisit if PCIe power management ever matters on this machine.
- All DankMaterialShell windows, spotlight, notifications, control center, and so on, share a single Wayland app_id, so a Sway window rule cannot target just one of them.
- `WLR_NO_HARDWARE_CURSORS=1` is documented but not set in `config/environment.d/vekrona.conf`. Only add it if the cursor becomes invisible, a known wlroots-on-NVIDIA symptom.
- Whether the snapper actions plugin (`etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions`) fires during an offline `dnf system-upgrade` transaction is unverified. Take the manual snapshot in the release upgrade procedure regardless.
- Every greetd login logs `gkr-pam: unable to locate daemon control file` at error priority. This is the stock `/etc/pam.d/greetd` from the `greetd` package (vekrona does not install or modify it): its `auth` phase runs `pam_gnome_keyring.so` before any keyring daemon exists, so the module logs this and stashes the password; the `session` phase's `pam_gnome_keyring.so auto_start` then starts `gnome-keyring-daemon` and unlocks the login keyring with that stashed password. Verified in the `vekrona-test` VM across a reboot and fresh login: `org.freedesktop.secrets` is served by the PAM-started `gnome-keyring-daemon` (the D-Bus-activated and socket-activated units stay inactive), the login collection's `Locked` property is `false`, and `secret-tool store`/`lookup` succeed with no password prompt.

## VM smoke test

`VM_NAME` and `VM_USER` (default `vekrona-test` and `vekrona`) are validated
by the Makefile against `[A-Za-z0-9._-]+`, starting with a letter or digit,
before any target runs.

```
make -C vm deps      # installs virt-install/virt-viewer/libvirt-client/inotify-tools/ImageMagick/python3-libvirt if missing, enables the virtqemud/virtnetworkd/virtstoraged sockets, starts and autostarts the libvirt "default" network, adds you to the libvirt group (log out and back in for that to take effect)
make -C vm create     # generates vm/ks-$(VM_NAME).cfg from vm/ks.cfg.in (one generated kickstart per VM name, gitignored, so `make create VM_NAME=foo` next to an existing vekrona-test VM regenerates the right file instead of reusing a stale hostname), generating a dedicated harness SSH key pair at vm/.ssh/id_ed25519 (ed25519, no passphrase, gitignored) if it doesn't exist yet, and substituting your personal SSH public key (first of ~/.ssh/id_ed25519.pub, id_rsa.pub, *.pub, or set VM_SSH_PUBKEY), the harness key, and VM_NAME (as the guest hostname) into the kickstart; virt-install: Fedora Everything netinstall of the release set by FEDORA_RELEASE in vm/Makefile (currently 44), with vm/install-tree.sh resolving the Fedora geo-redirector to one concrete mirror and verifying it serves the install tree before virt-install ever touches it (no retries: a redirector that does not itself redirect is rejected outright), + that kickstart (btrfs autopart, NOPASSWD sudo, password `vekrona` for graphical login, system sleep disabled in the guest because virtio-gpu does not survive suspend and resume (DMS would otherwise suspend an idle VM after 30 min and wedge Sway on its display), `%packages` limited to what the harness itself needs before any stage has run: `@core rsync qemu-guest-agent`; openssh-server is already an @core mandatory package; both the harness key and your personal key are authorized for the VM user); the --os-variant hardware profile is fedora<release> when the host's osinfo database knows it, otherwise the newest known profile plus a warning naming `osinfo-db-import --user --latest`; the VM gets a virtio video device, a local-only SPICE display (`--graphics spice,listen=127.0.0.1`), and a guest-agent channel requested explicitly; the serial console is logged to `/var/log/libvirt/qemu/$(VM_NAME)-serial0.log` (root-owned, read it with sudo) so an install or boot failure can be diagnosed afterwards; the domain is marked as owned by this harness in its libvirt metadata (see `destroy` below); the kickstart shuts the VM down after %post, then this target boots it with `virsh start`
make -C vm test       # connects only with the harness key (-i vm/.ssh/id_ed25519, IdentitiesOnly=yes, -F /dev/null and IdentityAgent=none so your ~/.ssh/config and any SSH agent, including 1Password, are never touched); waits for an IPv4 lease (vm/wait-for-ip.sh, event-driven: it watches the libvirt dnsmasq lease file with inotifywait rather than polling on a sleep), waits for SSH, enables linger for the VM user, rsyncs the repo in (excluding .git and vm/.ssh, so the harness key never leaves the host), runs ./install.sh --skip 10-nvidia (which installs everything the harness scripts below need: python3/inotify-tools are not in the kickstart, stage 30-packages installs them before session-check.sh ever runs; git is not installed by any stage or needed in the VM, since the repo arrives by rsync, not by clone), vm/session-check.sh, a vekrona-snapshot/vekrona-rollback round trip, reboots the VM and waits for it to actually reboot and for qemu-guest-agent to reconnect, both through libvirt domain events (vm/wait-for-reboot.py), then waits for SSH again, runs vm/rollback-check.sh against that snapshot number, requires `systemctl is-system-running --wait` to report `running` (a degraded boot, with any failed unit, fails the test and prints the failed units), and finally runs vm/login-manager-check.sh to prove the fresh-install login manager (stage 65-login-manager): greetd active, greetd enabled, default target graphical.target. One timed wall-clock wait remains, unlike every other wait here: SSH reachability itself, retried up to `SSH_CONNECT_ATTEMPTS` times, isolated in one `wait_for_ssh` helper in vm/Makefile (see TODO.md)
make -C vm destroy    # refuses to act on a domain that is not marked as owned by this harness (see `create` above); virsh destroy if running, then virsh undefine --remove-all-storage, then removes the generated vm/ks-$(VM_NAME).cfg
make -C vm adopt      # marks an existing domain as owned by this harness, for a domain `create` made before the ownership mark existed; requires its generated vm/ks-$(VM_NAME).cfg to already exist, as evidence this harness actually created it
make -C vm screenshot OUT=path.png   # saves a PNG of the current VM display to OUT, which must be an absolute path (virsh screenshot to PPM, converted with ImageMagick); fails if OUT is unset, relative, or the VM is not running
make -C vm viewer     # opens the VM display for a human with virt-viewer against qemu:///system
make -C vm type TEXT='hello'   # types TEXT into the VM as keystrokes, mapped to keycodes by vm/keymap.sh (US layout) and sent with virsh send-key
make -C vm key KEYS='KEY_LEFTMETA KEY_ENTER'   # sends one key combination to the VM with virsh send-key
```

Automation (`test` and `ssh`) authenticates as the VM user `vekrona` with a
throwaway harness key pair generated on demand at `vm/.ssh/id_ed25519`
(gitignored, never committed) by `make create`; `test` and `ssh` fail with a
clear message, instead of regenerating it, if that key pair is missing or
only half present (one of the two files without the other). It never uses
your personal key or any SSH agent. The kickstart also authorizes your
personal public key (`VM_SSH_PUBKEY`) for the same user, so you can log in by
hand at handover, and the password `vekrona` also works; this is a throwaway
VM on the libvirt NAT network, so a shared plaintext password is fine.

Four timeouts, all overridable on the `make` command line, bound the waits in
`test`: `IP_WAIT_TIMEOUT` (default 120s, for the DHCP lease),
`REBOOT_EVENT_TIMEOUT` (default 60s, for libvirt's reboot event),
`AGENT_RECONNECT_TIMEOUT` (default 300s, for qemu-guest-agent to reconnect
after reboot), and `SSH_CONNECT_ATTEMPTS` (default 60, retry count rather
than a duration, for the one remaining timed SSH wait above).

`vm/session-check.sh` starts a headless Sway session (`WLR_BACKENDS=headless`)
under `systemd-run --user`, waits for the Sway IPC socket, confirms
`sway-session.target` is active and starts `dms.service`, calls
`dms ipc call lock status`, and validates the xremap config with
`xremap-wlroots --validate-config`. `vm/rollback-check.sh` then confirms the
rollback left both `root` and a `root.old-*` subvolume at the top level, `/`
mounted from `[/root]`, and the `/.vekrona-rolled-back-from-<N>` marker in
place. After the reboot that follows, `vm/login-manager-check.sh` confirms
`systemctl is-active greetd`, `systemctl is-enabled greetd`, and
`systemctl get-default` is `graphical.target`, proving the fresh-install
login manager stage actually leaves the VM bootable straight into the
greeter. `make -C vm console` and `make -C vm ssh` give interactive access to
the VM in between, and `make -C vm viewer` gives graphical access.

What the VM cannot smoke-test, because the VM has none of the hardware
involved: the NVIDIA stage and every GPU feature that depends on it (stage
`10-nvidia` is always skipped in `make -C vm test`), the named 4K 240 Hz
output, Bluetooth, and anything that needs pointer input, such as an area
screenshot or a screen-recording region selection, since `make -C vm type`
and `make -C vm key` only send keystrokes.

## ISO and CI

`iso/` builds an installable Fedora 44 ISO (Sway/DMS baked in via a
first-boot install) on top of the official Fedora Everything netinstall, and
`.github/workflows/iso.yml` builds and tests it on every push, pull request,
and tag:

- `iso/fetch-netinst.sh <release> <dest-dir>` downloads and GPG/sha256-verifies
  the official Fedora Everything netinstall ISO for `<release>`, printing its
  path; a verified file already in `<dest-dir>` is reused instead of
  re-downloaded.
- `iso/build.sh --netinst <iso> --out <iso>` refuses to run against a dirty
  working tree (the ISO embeds a `git clone` of HEAD, so uncommitted changes
  would silently be missing from it) — commit or stash first. It points the
  cloned checkout's `origin` remote at the source repo's own `origin` URL, so
  the installed system can `git pull` for real, and every kickstart `%post`
  uses `--erroronfail` so a failing step aborts the install instead of
  continuing silently. It then runs `mkksiso` (Fedora 44 host, `lorax`
  installed) to produce the release ISO: interactive on boot, Anaconda asks
  for a disk and a user; with no `timezone` line, the installer defaults to
  `America/New_York` and shows a non-blocking warning on the hub, clearable
  by visiting Time & Date during install. With `--test-ssh-pubkey <file>` it
  instead produces a fully unattended test ISO: wipes the disk, installs
  btrfs, creates user `vekrona` (password `vekrona`, in `wheel`), enables
  sshd with that key authorized, boots with `console=ttyS0`, and reboots
  when Anaconda finishes. `mkksiso` rebuilds the ISO's EFI boot image
  (`mkefiboot`), which loop-mounts a small FAT image, so the container this
  runs in needs `/dev/loop-control` plus `--cap-add SYS_ADMIN --cap-add
  MKNOD --device /dev/loop-control --device-cgroup-rule='b 7:* rmw'
  --security-opt label=disable` (a rootful container; rootless podman
  refuses device-cgroup rules outright) — `iso/build.sh` itself `mknod`s
  `/dev/loop0`-`/dev/loop7` if missing so it never depends on the host
  already having free loop devices. `iso/Containerfile` plus `podman build
  -t vekrona-iso-builder -f iso/Containerfile .` and `sudo podman run --rm
  <the flags above> -v "$PWD:/src:Z" -w /src vekrona-iso-builder bash
  iso/build.sh ...` reproduce this locally.
- The installed system runs `vekrona-firstboot.service` once on first boot:
  it runs `./install.sh` as the `vekrona` user (skipping `10-nvidia` when
  there is no NVIDIA GPU), then writes `/var/lib/vekrona/firstboot.done` or
  `firstboot.failed` and reboots into `greetd` on success.
- `iso/qemu-test.sh <test.iso>` boots that test ISO under plain
  `qemu-system-x86_64` with KVM (UEFI via OVMF, 8 GiB RAM, 4 vCPUs, a 40G
  qcow2 disk, user-mode networking with an SSH port forward, and the serial
  console logged to a file). It runs the install once with `-no-reboot` so
  QEMU exits when Anaconda reboots, then boots the installed disk on its
  own; waits for SSH with the matching test private key
  (`VEKRONA_TEST_SSH_KEY`), then for the firstboot completion marker
  (printing `firstboot.failed` plus `journalctl -u vekrona-firstboot` and
  failing if firstboot failed), then for the post-firstboot reboot and SSH
  again; and finally asserts `systemctl is-system-running --wait` is
  `running` (printing failed units otherwise), `greetd` is active, and runs
  `vm/session-check.sh`, `vm/login-manager-check.sh`, `./install.sh --skip
  10-nvidia 70` (verify: warnings allowed, no `FAIL:`), and a
  `vekrona-snapshot`/`vekrona-rollback` round trip, over SSH with the same
  options as `vm/Makefile` (harness key only, `IdentitiesOnly`, `-F
  /dev/null`, `IdentityAgent=none`, no known-hosts file). Every wait is
  polled with a bounded, env-overridable timeout rather than a fixed sleep;
  on any failure it prints the serial console log tail before cleaning up
  its QEMU processes and temp files.

### Installer REPL

`iso/dev-installer.sh` boots the installer with a fresh, dev-built `updates.img`
served over HTTP, so Anaconda add-on edits can be iterated without rebuilding the
ISO each time.

**Usage:**
```
VEKRONA_DEV_USB="0a00:0a01 0a00:0a02" iso/dev-installer.sh
```

- `VEKRONA_DEV_USB` is a space-separated list of USB device VID:PID pairs to
  pass through to the QEMU VM. For YubiKeys, use `1050:0407` (or your key's ID).
- `--fresh-disk` creates a new qcow2 disk (otherwise reuses the existing one for
  faster iteration).
- `--iso <path>` points to a release ISO (defaults to `iso/out/vekrona-release.iso`).

Before running: ensure you have read/write access to the USB device nodes:
```
sudo setfacl -m u:$USER:rw /dev/bus/usb/BBB/DDD
```

Over SSH into the installer (port printed by the script):
```
ssh -i ~/.ssh/id_rsa -p <port> root@localhost
cat /tmp/anaconda.log
```

The script prints a build stamp showing the dev image was loaded (not the baked
ISO one), located at the path printed on stderr. This proves the `inst.updates=`
parameter worked and the bundled packages (`python3-fido2`, `libfprint`, etc.)
were extracted correctly.

The `iso.yml` workflow has three jobs: `build` (Fedora 44 container, caches
the downloaded netinstall ISO by release, builds both the release and a
throwaway-keyed test ISO, uploads both as artifacts), `test` (enables KVM on
the `ubuntu-latest` runner and runs `iso/qemu-test.sh` against the test ISO,
uploading the serial logs on any outcome), and `release` (tags only, attaches
the release ISO and its checksum to the GitHub release).

## Decisions log

The full rationale, every verified machine fact, and the complete
rollout and verification checklist behind this README live in
`docs/PLAN.md`. Read it before changing anything in stage `10-nvidia`, the
versionlocked set, or the cleanup stages (`90a-switch-dm`, `90b-remove`);
those decisions came out of an adversarial review and are easy to undo by
accident.
