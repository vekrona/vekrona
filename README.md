# vekrona

Personal Fedora 44 Workstation desktop: Sway plus DankMaterialShell (DMS) on
Quickshell, replacing an Omarchy-on-Fedora setup (omedora COPR, Hyprland,
Omarchy's Quickshell shell) on the same machine. Priorities in order: stability
first, gaming-ready second, and a macOS-style keyboard (Caps Lock as a Hyper
key, Cmd-style shortcuts) without breaking terminal control sequences. Built
for one desktop: Ryzen 7950X3D, RTX 4090, and a Dell AW3225QF (4K, 240 Hz,
QD-OLED) on output DP-7. The migration runs stage by stage, in place, on that
machine, with a clean Fedora 44 VM used to smoke-test each stage first.

## Layout of the repo

| Path | Contents |
|---|---|
| `install.sh` | stage runner: parses flags and stage names, refreshes sudo, runs `stages/NN-*.sh` in order, stamps completion under `~/.local/state/vekrona` |
| `lib/common.sh` | shared bash helpers (`log`, `die`, `ensure_*`, `assert_*`), sourced by every stage and by `bin/vekrona-rollback` and `bin/vekrona-snapshot` |
| `stages/*.sh` | one script per stage, numbered so the run order is visible in a directory listing |
| `config/` | source of truth for dotfiles; stage `50-user` symlinks these into `$HOME` |
| `etc/` | system files installed into `/etc` by `ensure_root_file` |
| `bin/vekrona-*` | the CLI tools; stage `50-user` symlinks the whole directory into `~/.local/bin` |
| `fonts/` | vendored JetBrainsMono Nerd Font (OFL, v3.5.1), symlinked into `~/.local/share/fonts/vekrona` |
| `vm/` | libvirt smoke-test harness: Makefile, kickstart, session and rollback checks |
| `docs/PLAN.md` | the design record: decisions, verified machine facts, rollout, verification, known issues |
| `TODO.md` | open follow-ups not yet folded into a stage |

## Install

### Prerequisites

- Fedora 44 Workstation.
- Btrfs root subvolume, with `/boot` on its own filesystem (this machine has it on ext4). Stage `20-snapper` and `bin/vekrona-rollback` assume btrfs and snapper.
- A user account with sudo access. `install.sh` refuses to run as root itself; stages call `sudo` where they need it.

### Clone and run

```
git clone https://github.com/vekrona/vekrona ~/wrk/vekrona
cd ~/wrk/vekrona
./install.sh
```

With no arguments, `install.sh` runs the default stage list in this order:
`00-repos 20-snapper 10-nvidia 30-packages 40-system 50-user 60-gaming 70-verify`.
Snapper runs before NVIDIA so a snapshot exists before stage `10-nvidia` touches
the driver.

### Stage semantics

- Name a stage by its number prefix or its full name: `./install.sh 30` and `./install.sh 30-packages` do the same thing.
- `--skip STAGE` drops one stage from the run, and also drops it from the set that `70-verify` checks.
- Pass explicit stage names to run a subset, for example `./install.sh 10 30` (used later to re-lock package versions after a Fedora upgrade, see Update policy below).
- `90a-switch-dm` and `90b-remove` never run by default; name them explicitly, e.g. `./install.sh 90a-switch-dm`.
- `--reset-dms-settings` overwrites `~/.config/DankMaterialShell/settings.json` from the seed file. Without it, an existing `settings.json` is left alone on every re-run, so DMS settings changed by hand survive a re-run of stage `50-user`.
- Each stage starts with `sudo -v`, so expect one password prompt per stage. There is no background loop refreshing the sudo timestamp mid-stage, so a long stage can prompt again partway through.
- Every stage is written to be idempotent: the `ensure_*` helpers in `lib/common.sh` check the current state before changing anything, so re-running `./install.sh` after a partial or failed run only touches what is still missing.
- `ensure_symlink` never overwrites a real file silently. If the symlink target already exists and is not itself a symlink, it gets moved to `<target>.pre-vekrona` first. If that backup path is already taken, the stage fails instead of picking a second name, because a second collision at the same path usually means an earlier conflict was never resolved by hand.

### Rollout order

`docs/PLAN.md` prescribes a specific, gated rollout for migrating a machine for
the first time, each step confirmed before moving to the next:

1. VM first. `make -C vm create`, then `make -C vm test`, which runs `./install.sh --skip 10-nvidia` inside the VM, a headless Sway session check, and a real snapshot/rollback round trip (see VM smoke test below).
2. Host, no reboot needed: stages `00`, `20`, `30`, `40`, `50`, `60`.
3. Host, NVIDIA: stage `10`, reboot, `./install.sh 70`, then a real `vekrona-rollback` to the pre-`10` snapshot and back.
4. Host, Sway validation: log into the Sway session and check the 240 Hz output, the Hyper layer, the Cmd layer in a browser versus a terminal, lock/idle/suspend, DMS features, all four themes, the webapps, and autostart apps such as 1Password.
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
| Hyper+1..9 | switch to workspace 1 through 9 |
| Hyper+h/j/k/l, arrow keys | focus left/down/up/right |
| Hyper+r | enter resize mode (h/j/k/l or arrows resize, Return or Escape exits) |
| Hyper+f | toggle fullscreen |
| Hyper+w | kill the focused window |
| Hyper+t | toggle floating |
| Hyper+e | toggle split layout |
| Hyper+Print | `vekrona-screenshot` |
| Hyper+Shift+c | `vekrona-caffeine` |
| Hyper+Shift+n | `dms ipc call night toggle` |
| Hyper+Shift+t | `vekrona-theme next` |
| XF86Audio* / XF86MonBrightness* | `dms ipc call audio ...` / `dms ipc call brightness ...` |

Hyper+Shift is the second layer, used for moving things instead of focusing
them:

| Binding | Action |
|---|---|
| Hyper+Shift+1..9 | move the focused container to workspace 1 through 9 |
| Hyper+Shift+h/j/k/l, arrow keys | move the focused container left/down/up/right |
| Hyper+Shift+Print | `vekrona-record` |

Shift is not folded into the Hyper mask itself: Hyper is exactly
Ctrl+Alt+Super, and Hyper+Shift is a separate binding on top of it. Putting
Shift inside the Hyper mask would make Hyper+Shift+X carry the same modifier
mask as some other Hyper+X binding and silently overwrite it.

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
reaches the shell for things like Ctrl+C. Only word navigation is remapped
there (Alt+Left/Right to Ctrl+Left/Right, Alt+Backspace to Ctrl+Backspace).
Copy and paste in ghostty come from ghostty's own keybinds instead
(`config/ghostty/config`: `super+c=copy_to_clipboard`,
`super+v=paste_from_clipboard`), not from xremap.

`xkb_options grp:alts_toggle` in `config/sway/config` toggles between the two
configured keyboard layouts, `us` and `ua`, by pressing Left Alt and Right Alt
together.

## Daily operations

Theme (applies both the DMS color scheme and a matching 4K wallpaper, and
remembers the current theme in `~/.local/state/vekrona/theme` so `next`
cycles correctly; the four themes are `tokyo-night`, `catppuccin-mocha`,
`gruvbox-dark`, `nord`, and their wallpapers are generated solid/gradient
placeholders, swap them for real images if wanted):

```
vekrona-theme <name>
vekrona-theme next
vekrona-theme list
```

Caffeine (a fixed wall-clock duration is the point, not something to work
around): runs `systemd-inhibit --what=sleep` for the given duration and sends
a desktop notification, also bound to Hyper+Shift+c.

```
vekrona-caffeine 30m
vekrona-caffeine 1h
vekrona-caffeine 2h
vekrona-caffeine status
vekrona-caffeine off
```

Screenshot and recording:

```
vekrona-screenshot area     # grim + slurp region capture, opens in swappy, saved to ~/Pictures/Screenshots
vekrona-screenshot output   # full output, same pipeline
vekrona-record              # slurp region select, wf-recorder toggle, saved to ~/Videos/Recordings
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

Wraps `sudo snapper -c root create -c number -d "<description>"`. Every dnf
transaction also gets an automatic pre/post snapshot pair from the actions
plugin installed by stage `20-snapper`.

Rollback:

```
sudo vekrona-rollback <N>
```

`vekrona-rollback` self-elevates through sudo if not already root. It mounts
the top-level btrfs subvolume (`subvolid=5`), renames the live `root`
subvolume to `root.old-<timestamp>`, snapshots `.snapshots/<N>/snapshot` as
the new writable `root`, and moves `.snapshots` across so the restored root
keeps its own snapshot history. It asks for confirmation unless run with
`--yes`, and warns if the currently booted kernel has no matching
`/lib/modules/<kernel>` directory inside the target snapshot. `/boot` is a
separate ext4 filesystem and is never touched by a rollback, so rolling back
to an old snapshot can leave a root whose kernel modules do not match what is
actually in `/boot`; check that warning before rebooting. Reboot afterward
(`systemctl reboot`) to boot into the restored root.

To look at a snapshot without committing to it: at the GRUB menu, press `e`
on the boot entry, change `subvol=root` on the kernel command line to
`subvol=/.snapshots/<N>/snapshot`, then boot it (Ctrl+X or F10). The snapshot
itself is read-only, so this boots into it for inspection without writing
anything, and the edit is not saved, so the next normal boot is unaffected.

Verifying a run:

```
./install.sh 70
```

Runs the assertions in `stages/70-verify.sh` for whichever stages were part
of the same `install.sh` invocation.

Steam launch option, wraps a game with ScopeBuddy using
`config/scopebuddy/scb.conf` (`-f -W 3840 -H 2160 -r 240 --adaptive-sync -e`):

```
scb -- %command%
```

MangoHud toggle in-game: Shift_R+F12 (`config/mangohud/MangoHud.conf`,
`toggle_hud=Shift_R+F12`).

## Update policy

Stay one Fedora release behind: this machine runs F44 until F46 reaches GA.
Staying a release behind gives the NVIDIA driver, Sway/wlroots, and DMS/Qt
time to catch up before this machine takes the upgrade.

The versionlocked set, applied by the stage that installs each package and
recorded in `/etc/dnf/versionlock.toml`:

- Stage `30-packages` locks `sway`, the installed wlroots0.19-providing package, `dms`, `quickshell`, `qt6-qtbase`, `qt6-qtdeclarative`, `qt6-qtwayland`, `xremap-wlroots`, the whole compositor and shell stack, so a routine `dnf upgrade` cannot pull one of them out from under versions that were actually tested together.
- Stage `10-nvidia` locks `akmod-nvidia` and every installed `xorg-x11-drv-nvidia*` package, so a routine upgrade cannot install a newer proprietary driver against an untested kernel.

`stages/70-verify.sh` warns when a lock's `.fcNN` suffix no longer matches the
running Fedora version, which is the signal that a lock is now holding back
more than intended.

Release upgrade procedure:

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
- Units and IME state left over from Omarchy, `omarchy-fcitx5`, `omarchy-crash-watch`, and others, plus `/usr/lib/environment.d/10-omarchy-fcitx.conf`, keep running inside Sway until stage `90b-remove` actually removes the omedora packages that own them.
- `pcie_aspm=off` is set as a kernel argument by stage `10-nvidia` without a recorded reason. Revisit if PCIe power management ever matters on this machine.
- All DankMaterialShell windows, spotlight, notifications, control center, and so on, share a single Wayland app_id, so a Sway window rule cannot target just one of them.
- `WLR_NO_HARDWARE_CURSORS=1` is documented but not set in `config/environment.d/vekrona.conf`. Only add it if the cursor becomes invisible, a known wlroots-on-NVIDIA symptom.
- Whether the snapper actions plugin (`etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions`) fires during an offline `dnf system-upgrade` transaction is unverified. Take the manual snapshot in the release upgrade procedure regardless.

## VM smoke test

```
make -C vm deps      # installs virt-install, virt-viewer, libvirt-client if missing
make -C vm create     # virt-install: Fedora 44 Everything netinstall + vm/ks.cfg kickstart (btrfs autopart, NOPASSWD sudo, git + openssh-server); reboots when done
make -C vm test       # waits for SSH, rsyncs the repo in (excluding .git), runs ./install.sh --skip 10-nvidia, vm/session-check.sh, a vekrona-snapshot/vekrona-rollback round trip, vm/rollback-check.sh, a reboot, and a final subvol=/root check
make -C vm destroy    # virsh destroy, then virsh undefine --remove-all-storage
```

`vm/session-check.sh` starts a headless Sway session (`WLR_BACKENDS=headless`)
under `systemd-run --user`, waits for the Sway IPC socket, confirms
`sway-session.target` and `dms.service` are active, calls
`dms ipc call lock status`, and validates the xremap config with
`xremap-wlroots --validate-config`. `make -C vm console` and `make -C vm ssh`
give interactive access to the VM in between.

## Decisions log

The full rationale, every verified machine fact, and the complete
rollout and verification checklist behind this README live in
`docs/PLAN.md`. Read it before changing anything in stage `10-nvidia`, the
versionlocked set, or the cleanup stages (`90a-switch-dm`, `90b-remove`);
those decisions came out of an adversarial review and are easy to undo by
accident.
