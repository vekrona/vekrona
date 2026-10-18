# Daily use

Applications, the `vekrona-*` commands, snapshots and rollback, and the bar's workspace plugin.

## Applications

Vekrona installs a curated set of applications via the following channels:

- **1Password + CLI**: vendor RPM repository (`downloads.1password.com/linux/rpm/stable`)
- **Proton VPN (GTK app + CLI)**: vendor RPM repository (`repo.protonvpn.com/fedora-$releasever-stable`, `repo_gpgcheck=1`; the key is vendored per Fedora release and pinned, and `protonvpn-stable-release` is not installed; the app shows in the bar's tray, the `proton-vpn-daemon` service `me.proton.vpn.split_tunneling` starts with the RPM)
- **herdr**: COPR `rossetnocpes/herdr` (single-package COPR, upstream Rust builds for f43–rawhide)
- **Zed**: Flathub Flatpak `dev.zed.Zed` (system-wide install, requires hardware Vulkan driver; Fedora-built RPMs freeze on F44 due to GCC 16/LLVM ABI bug rhbz#2464281, unresolved; updates via `flatpak update`)
- **Spotify**: Firefox webapp with Widevine (replaces the `com.spotify.Client` Flatpak; downloads the Widevine CDM on first launch)
- **Signal, OBS Studio, Obsidian**: Flathub Flatpaks (system-wide install, `VEKRONA_FLATPAKS`; Obsidian is closed source but has no web version and works on local vault files)
- **Syncthing**: Fedora repository (the `syncthing` RPM runs as your user service `syncthing.service`; its web GUI at `http://127.0.0.1:8384/` is the Firefox webapp below, behind a login that stage 50 generates: user `vekrona`, password in `~/.local/state/vekrona/syncthing-gui-password`, which you save in the webapp's Firefox once)
- **Proton Mail (with Calendar), Pass and Authenticator**: native apps from Proton's own feeds (see [updates](updates.md))
- **Telegram, Discord, SoundCloud, YouTube, WhatsApp, Syncthing GUI**: Firefox webapps (Spotify above; `vekrona-webapp <app>` starts one, the full list is under Daily operations)
- **Steam**: RPM Fusion (already installed; stage 60 sets Steam Play preset to `proton_experimental` for all titles)
- **Nix**: Fedora 44's own `nix` and `nix-daemon` RPMs (flakes enabled by default; `/nix` lives on its own btrfs subvolume `nix` separate from root, so rollbacks never include the Nix store)
- **devbox**: installed for the desktop user with `nix profile install` from a pinned nixpkgs commit (`DEVBOX_NIXPKGS_REV` in stage 50)
- **Tailscale**: Fedora `updates` repository (no vendor repo needed; `tailscaled` enabled and active, you are operator: `tailscale up` without sudo; tray icon runs via user systemd unit)
- **btop**: Fedora repository
- **Non-free codecs**: RPM Fusion (swap `ffmpeg-free` to `ffmpeg`, add freeworld gstreamer plugins, `mesa-va-drivers-freeworld`, openh264 via already-enabled `fedora-cisco-openh264`; VDPAU packages no longer exist in F44)

## Daily operations

### Updates

The system checks for updates every morning at 9:00 (and five minutes after boot). When something is pending, a
toast says "Updates available" and lists what changes, one line per group (System packages, Flatpak,
Proton). A group with more than five updates shows its count and the first five.

- **Install now** updates in the background and does not restart anything. The toast stays on screen, or in the
  notification center, until midnight.
- **Not tonight** skips the midnight update for today.
- Ignore the toast and the computer installs the updates at midnight: it wakes itself, asks you first if you are
  at it, and reboots into the update.

You see each set of updates once. If the check runs before you log in, the toast appears when the session starts.

The launcher's Power view (`/power`, or the `Power` tab) gains two items while updates are pending, placed
before Restart and Shut down: **Update and restart** and **Update and shut down**. Like Restart, each needs a second
press to run. They install the updates in an offline update and then restart or power off the computer. When
nothing is pending the items are not there.

### Default firewall zone

Stage `40-system` (`ensure_default_zone`, `lib/firewall.sh`) makes `public` the default firewalld zone. Fedora Workstation's own
default, `FedoraWorkstation`, accepts every TCP and UDP port from 1025 up from the local network. `public` gets exactly what
vekrona runs: `mdns` and `dhcpv6-client` (public's own), `syncthing` (22000/tcp and udp, 21027/udp for local discovery; its web
GUI stays on 127.0.0.1), `steam-streaming` and `steam-lan-transfer` (Steam is installed by stage 30: Remote Play and local game
transfer), and UDP 6001-6010 for AirPlay (`ensure_airplay_ports`). ssh is closed outside the tailnet (below). A new service is one more
word in `DEFAULT_ZONE_SERVICES` (`lib/firewall.sh`). If a NetworkManager connection is pinned to the `FedoraWorkstation` zone
(`nmcli -f connection.zone connection show <name>`), stage 40 reports it and `70-verify` fails until
`nmcli connection modify <name> connection.zone ''` clears the pin. The `tailnet` zone is unchanged.

### Remote access (ssh over the tailnet)

Stage `40-system` makes sshd take public keys only (`/etc/ssh/sshd_config.d/10-vekrona.conf`: no passwords, no
keyboard-interactive logins, no root login) and open it to the tailnet only. firewalld has a `tailnet` zone
(`/etc/firewalld/zones/tailnet.xml`) that holds `tailscale0` and the tailnet's address ranges (`100.64.0.0/10`,
`fd7a:115c:a1e0::/48`) and allows `ssh` and nothing else; every other zone loses its `ssh` service, and a zone that still lets ssh in
(an open port 22, or a target that accepts everything, as `trusted`, a hotspot or Docker have) gets a reject rule for it, so the LAN
cannot reach sshd. sshd itself keeps listening on every address, because tailscaled may come up after it. While you are
logged in over ssh from outside the tailnet (an install over the LAN), the stage keeps ssh in those zones so that it
never cuts its own session off, reports that as a failure, and `70-verify` fails until you run `./install.sh 40` again
from a console or over the tailnet. Put your public key in `~/.ssh/authorized_keys` before you rely on it;
the stage warns when that file is empty. A machine without firewalld running gets a warning instead of the zone.

The Headscale policy decides who may reach port 22. On `mesh.xiii.site`, the policy has to contain this (this host is
`100.64.0.7`, the user is `admin@`):

```json
"groups": { "group:admin": ["admin@"] },
"hosts":  { "vekrona": "100.64.0.7" },
"grants": [
  { "src": ["group:admin"], "dst": ["vekrona"], "ip": ["tcp:22"] }
]
```

Remove any broader `*:*` rule: while it exists, every node on the tailnet may open port 22 here, not only the
admin group.

AirPlay: if the default zone does not open them already (`public`, not `FedoraWorkstation`), stage 40 opens UDP 6001-6010
there, because AirPlay's timing and control channels use those ports.

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
around): the bar's cup icon is emphasized while a keep-awake session runs. Left
click opens a menu (a second click closes it): End session (when active, with the
target and the time left, in days from 24 hours on), Stay awake for (1h/2h/5h/12h/24h
presets), Stay awake until (the day pill opens a month grid for the next 30 days; the
time is typed as HH:MM, H:MM or HHMM, or stepped by 5 minutes with Up, Down or the wheel;
Enter starts), Wait for download (in-progress files in Downloads) and Wait for process
(apps with open windows).
Hyper+Shift+c toggles 1h or off. A command the CLI refuses, like a time it cannot read,
shows a notification with the reason. A download wait ends when the file is renamed or
deleted, which is what a browser does when it finishes, or after 60 s without a write,
and the end notification says which. `vekrona-caffeine` CLI (start, check status, end a
session): runs a transient systemd user unit wrapping `systemd-inhibit --what=sleep`
(blocks a manual suspend and logind's idle suspend alike; swayidle keeps locking and
switching the screen off, which an `idle` inhibitor would stop;
`etc/polkit-1/rules.d/50-vekrona-caffeine.rules` lets the unit hold it without a
password), and sends a desktop notification on start and end; also bound to
Hyper+Shift+c.

```
vekrona-caffeine for 1h                    # a span: 1h, 90min
vekrona-caffeine until 14:30               # the next 14:30, today or else tomorrow
vekrona-caffeine until "2026-10-20 08:00"  # a date and time
vekrona-caffeine file ~/Downloads/x.iso.part       # until it is renamed or deleted, or 60 s without a write
vekrona-caffeine file ~/Downloads/x.iso.part x.iso # the same, with the name to show
vekrona-caffeine pid 1234                  # until the process exits, shown by its command name
vekrona-caffeine pid 1234 firefox          # the same, with the name to show
vekrona-caffeine status
vekrona-caffeine off
vekrona-caffeine toggle                    # stops it if running, else starts it for 1h
```

Screenshot and recording:

```
vekrona-screenshot screen       # focused monitor
vekrona-screenshot area         # drag a rectangle or click a window
vekrona-screenshot window       # click a window only
vekrona-screenshot --clipboard screen   # copy to clipboard, no file
vekrona-screenshot --clipboard area     # copy to clipboard, no file
vekrona-screenshot --clipboard window   # copy to clipboard, no file
vekrona-record toggle           # slurp region select, systemd-run transient user unit toggle, saved to ~/Videos/Recordings
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
`config/scopebuddy/scb.conf` (`-f`, plus the width, height and refresh rate of the focused output, read from Sway at launch):

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
