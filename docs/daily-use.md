# Daily use

Applications, the `vekrona-*` commands, snapshots and rollback, and the bar's workspace plugin.

## Applications

Vekrona installs a curated set of applications via the following channels:

- **1Password + CLI**: vendor RPM repository (`downloads.1password.com/linux/rpm/stable`)
- **herdr**: COPR `rossetnocpes/herdr` (single-package COPR, upstream Rust builds for f43–rawhide)
- **Zed**: Flathub Flatpak `dev.zed.Zed` (system-wide install, requires hardware Vulkan driver; Fedora-built RPMs freeze on F44 due to GCC 16/LLVM ABI bug rhbz#2464281, unresolved; updates via `flatpak update`)
- **Spotify**: Firefox webapp with Widevine (replaces the `com.spotify.Client` Flatpak; downloads the Widevine CDM on first launch)
- **Signal, OBS Studio**: Flathub Flatpaks (system-wide install, `VEKRONA_FLATPAKS`)
- **Telegram, Discord, SoundCloud, YouTube, WhatsApp**: Firefox webapps
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
vekrona-webapp soundcloud
vekrona-webapp telegram
vekrona-webapp discord
```

## Daily operations

Theme (applies the DMS color scheme and a matching 4K
wallpaper, and remembers the current theme in `~/.local/state/vekrona/theme`
so `next` cycles correctly; the four themes are `tokyo-night`,
`catppuccin-mocha`, `gruvbox-dark`, `nord`, and their wallpapers are
generated solid/gradient placeholders, swap them for real images if wanted).

vekrona leaves terminal colors alone. Ghostty uses its own defaults, or
whatever your Ghostty config sets. vekrona ships no Ghostty config and writes
nothing under `~/.config/ghostty`, because that directory is often a symlink
into a dotfiles repo. Stage `50-user` sets the DMS setting
`matugenTemplateGhostty` to `false`, so DMS does not write its
`themes/dankcolors` file there either. The one thing stage `50-user` removes
there is the config link older installs made into the vekrona checkout, and
only while it points there. Copy and paste in Ghostty are Ghostty's own
Ctrl+Shift+C and Ctrl+Shift+V, because the Super layer skips terminals (see
keyboard.md).

DMS and GTK application colors are a separate path and still come from DMS.
The theme content lives in `~/.local/state/vekrona/active-theme.json`,
which `customThemeFile` in the DMS settings seed points at from the first
session onward, so DMS watches that one file and reloads it on every
write; the script writes the new theme into it, then waits for DMS to
confirm the new colors (via `inotifywait` on `~/.config/gtk-4.0/dank-colors.css`, which DMS
generates as a side effect, so it needs `inotify-tools`) and exits
non-zero with a clear message if the theme did not take within the wait,
without retrying or restarting the shell itself. DMS seeds the wallpaper
for the first session from `~/.local/state/DankMaterialShell/session.json`,
so it shows correctly without any `vekrona-theme` call. The DMS colors for
that very first session are not guaranteed: DMS has an internal startup
race between checking whether `matugen` is available and loading the
custom theme file, and when it loses that race it does not retry, so GTK
application colors can stay at GTK defaults until the first
`vekrona-theme <name>` call. No event exists to reliably wait on for that
race from outside DMS, so this is not automated.

The same startup race is why `runDmsMatugenTemplates` and
`matugenTemplateGtk` must stay on. Without them DMS never regenerates the GTK
color files after it wins the race, and `vekrona-theme` waits on one of those
files. The seed leaves both keys out, so DMS's default of `true` applies.
Stages `50-user` and `70-verify` assert that neither is `false`, which
catches anyone turning them off by hand. `matugenTemplateGhostty` goes the
other way. Stage `50-user` sets it to `false` on fresh and existing installs,
and stage `70-verify` checks it.

```
vekrona-theme <name>
vekrona-theme next
vekrona-theme list
```

Each `vekrona-theme` call also runs `vekrona-gtk-theme`, which writes
`~/.config/gtk-3.0/gtk.css` and `~/.config/gtk-4.0/gtk.css` from the same
active theme and selects `adw-gtk3-dark` with `prefer-dark`, so GTK apps
(file choosers, swappy, Firefox dialogs) match the desktop instead of light
Adwaita. It refuses to overwrite a `gtk.css` it did not generate. GTK apps
that are already running keep their old colors until restarted.

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
vekrona-screenshot screen       # focused monitor
vekrona-screenshot area         # drag a rectangle or click a window (default)
vekrona-screenshot window       # click a window only
vekrona-screenshot --clipboard screen   # copy to clipboard, no file
vekrona-screenshot --clipboard area     # copy to clipboard, no file
vekrona-screenshot --clipboard window   # copy to clipboard, no file
vekrona-record                  # slurp region select, systemd-run transient user unit toggle, saved to ~/Videos/Recordings
```

Super+Shift+3/4/5 work like Cmd+Shift+3/4/5 on macOS, and adding Ctrl copies to the clipboard without saving a file. In area mode, click a window or drag a rectangle. Saved shots are also copied to the clipboard, and the notification has Edit (opens swappy) and Delete (moves the shot to the trash) buttons.

Webapps (each opens a dedicated Firefox profile and window, set up by stage
`50-user` from `config/firefox/webapps/<app>/`):

```
vekrona-webapp youtube
vekrona-webapp whatsapp
vekrona-webapp spotify
vekrona-webapp soundcloud
vekrona-webapp telegram
vekrona-webapp discord
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
`config/scopebuddy/scb.conf` (`-f -W 3840 -H 2160 -r 240`):

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
