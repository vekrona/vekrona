# Daily use

Applications, the `vekrona-*` commands, snapshots and rollback, and the bar's workspace plugin.

## Applications

Vekrona installs a curated set of applications via the following channels:

- **1Password + CLI**: vendor RPM repository (`downloads.1password.com/linux/rpm/stable`)
- **herdr**: COPR `rossetnocpes/herdr` (single-package COPR, upstream Rust builds for f43–rawhide)
- **Zed**: Flathub Flatpak `dev.zed.Zed` (system-wide install, requires hardware Vulkan driver; Fedora-built RPMs freeze on F44 due to GCC 16/LLVM ABI bug rhbz#2464281, unresolved; updates via `flatpak update`)
- **Spotify**: Firefox webapp with Widevine (replaces the `com.spotify.Client` Flatpak; downloads the Widevine CDM on first launch)
- **Steam**: RPM Fusion (already installed; stage 60 sets Steam Play preset to `proton_experimental` for all titles)
- **Nix**: Fedora 44's own `nix` and `nix-daemon` RPMs (flakes enabled by default; `/nix` lives on its own btrfs subvolume `nix` separate from root, so rollbacks never include the Nix store)
- **devbox**: installed via `nix profile install nixpkgs#devbox` for the desktop user
- **Tailscale**: Fedora `updates` repository (no vendor repo needed; `tailscaled` enabled and active, you are operator: `tailscale up` without sudo; tray icon runs via user systemd unit)
- **btop**: Fedora repository
- **Non-free codecs**: RPM Fusion (swap `ffmpeg-free` to `ffmpeg`, add freeworld gstreamer plugins, `mesa-va-drivers-freeworld`, openh264 via already-enabled `fedora-cisco-openh264`; VDPAU packages no longer exist in F44)

Webapps are available as follows:

```
vekrona-webapp youtube
vekrona-webapp whatsapp
vekrona-webapp spotify
```

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
vekrona-webapp spotify
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
`/.vekrona-rolled-back-from-<N>`, holding the name of the backup subvolume
(`root.old-<timestamp>`), so a later check can confirm that this rollback
happened and which backup it left. It asks for confirmation unless run with `--yes`, and refuses to
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
`config/scopebuddy/scb.conf` (`-f -W 3840 -H 2160 -r 240 -e`):

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
