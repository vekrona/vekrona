# Daily use

Applications, the `vekrona-*` commands, snapshots and rollback, and the bar's workspace plugin.

## Applications

Vekrona installs a curated set of applications via the following channels:

- **1Password + CLI**: vendor RPM repository (`downloads.1password.com/linux/rpm/stable`)
- **herdr**: COPR `rossetnocpes/herdr` (single-package COPR, upstream Rust builds for f43–rawhide)
- **Zed**: Flathub Flatpak `dev.zed.Zed` (system-wide install, requires hardware Vulkan driver; Fedora-built RPMs freeze on F44 due to GCC 16/LLVM ABI bug rhbz#2464281, unresolved; updates via `flatpak update`)
- **Spotify**: Firefox webapp with Widevine (replaces the `com.spotify.Client` Flatpak; downloads the Widevine CDM on first launch)
- **Signal, OBS Studio, Obsidian**: Flathub Flatpaks (system-wide install, `VEKRONA_FLATPAKS`; Obsidian is closed source but has no web version and works on local vault files)
- **Syncthing**: Fedora repository (the `syncthing` RPM runs as your user service `syncthing.service`; its web GUI at `http://127.0.0.1:8384/` is the Firefox webapp below)
- **Telegram, Discord, SoundCloud, YouTube, WhatsApp, Syncthing GUI**: Firefox webapps
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
vekrona-webapp syncthing
```

## Daily operations

### Display settings

Sway uses each monitor's preferred mode with VRR off. Put your own `output` lines (mode, scale, position) in a file in `~/.config/sway/config.d/`, which the repo does not track and `config/sway/config` includes last. Find the identifier with `swaymsg -t get_outputs`, for example `output "<make> <model> <serial>" mode 3840x2160@120Hz scale 1.5`.

Theme: `vekrona-theme dark|light|next|list` switches the Vekrona Design System
between its two modes and remembers the mode in `~/.local/state/vekrona/theme`
so `next` cycles correctly. The wallpaper is a solid color, the mode's `bg`
token, set by a Sway `output * bg` line.

vekrona leaves terminal colors alone. Ghostty uses its own defaults, or
whatever your Ghostty config sets. vekrona ships no Ghostty config and writes
nothing under `~/.config/ghostty`, because that directory is often a symlink
into a dotfiles repo. The one thing stage `50-user` removes
there is the config link older installs made into the vekrona checkout, and
only while it points there. Copy and paste in Ghostty are Ghostty's own
Ctrl+Shift+C and Ctrl+Shift+V, because the Super layer skips terminals (see
keyboard.md).

### Terminal font (Ghostty)

Ghostty ignores fontconfig's `monospace`, and vekrona ships no Ghostty config
(PLAN decision 4), so Ghostty keeps its embedded JetBrains Mono until you opt
in. To use the system mono font, add this line to your Ghostty config, with
the absolute path of your vekrona checkout:

```
config-file = /path/to/vekrona/docs/ghostty-fonts.conf
```

or copy the two `font-family` lines from [ghostty-fonts.conf](ghostty-fonts.conf).
Both lines are needed: the Nerd-patched AtkynsonMono lacks the backtick, so
Ghostty takes it from Atkinson Hyperlegible Mono, the second family.

The design lives in `config/tokens.json`, copied verbatim from the Vekrona
Design System; never edit it by hand, re-import the design by copying the file.
`bin/vekrona-render-theme` reads it with the mode and `config/design.json` and
generates `~/.local/state/vekrona/active-theme.json`, GTK 3/4 css, gsettings,
qt6ct, the Sway drop-in, Firefox userChrome and rofi from it. vekrona-shell and
vekrona's other Quickshell apps read the generated `active-theme.json` (shell,
lock screen) or `tokens.json` itself (app switcher), so the generated file is
output, never input. The shell reloads it on every write, so `vekrona-theme`
only has to run the renderer: it records the mode, renders, and restores the
previous files and exits non-zero if the renderer fails. It never retries or
restarts the shell itself.

```
vekrona-theme dark
vekrona-theme light
vekrona-theme next
vekrona-theme list
```

Each `vekrona-theme` call also runs `bin/vekrona-render-theme`, which writes
`~/.config/gtk-3.0/gtk.css` and `~/.config/gtk-4.0/gtk.css`, selects
`adw-gtk3` (dark mode: `adw-gtk3-dark`) with `prefer-dark` or `prefer-light`,
and sets the GTK font keys from the tokens, so GTK apps (file choosers,
swappy, Firefox dialogs) follow the mode. It refuses to overwrite a `gtk.css` it did
not generate. GTK apps that are already running keep their old colors until
restarted. Firefox and Qt applications need a restart to pick up the new
theme; Qt apps additionally need one re-login for the `QT_QPA_PLATFORMTHEME=qt6ct`
environment variable to take effect. Qt's Fusion style keeps its small corners,
which the design does not allow elsewhere.

The design has radius 0, no shadows, a quiet focus (the focused control's own
1px border turns `focus` with a 1px `focus-inner` line just inside it, never an
offset ring) and one selection highlight: the `selected` fill under `ink` text.
`config/design.json` holds `radius`, the one toolkit knob that is
not a design token. Gaps and padding come from the spacing
tokens (`space-2` is 8, `space-3` is 12). To change the look, change
`config/design.json` or re-import `config/tokens.json`, then run
`./install.sh 50-user` to apply.

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
vekrona-webapp syncthing
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

## The Desktops widget

The shell's Desktops widget (`config/vekrona-shell/Desktops.qml`) always shows
desktops 1-5, even empty, plus any desktop 6-10 that currently exists, because
Sway deletes an empty workspace as soon as you focus away from it. Click a
desktop to switch (`workspace number N` over the Sway IPC socket via
`Quickshell.I3`), scroll over the widget to step through the shown desktops.
Focused, occupied (has a window) and urgent desktops use the `accentInk`,
`ink` and `dangerInk` tokens; the focused one also gets the `selected` fill.
