# Daily use

Applications, the `vekrona-*` commands, snapshots and rollback, and the bar's workspace plugin.

## Applications

Vekrona installs a curated set of applications via the following channels:

- **1Password + CLI**: vendor RPM repository (`downloads.1password.com/linux/rpm/stable`)
- **rune**: the default editor (`$EDITOR`; `.md` and text files open in Ghostty); Zed remains for GPU editing. A pinned GitHub release RPM, see [updates](updates.md#rune)
- **VPN (`vekrona-vpn`)**: WireGuard connections of NetworkManager for Mullvad, Proton or any provider's `.conf`, behind an nftables kill switch that rejects (so programs fail at once) whatever does not leave through the tunnel; no daemon of its own. Proton's own VPN app is not installed. See [VPN](#vpn)
- **herdr**: COPR `rossetnocpes/herdr` (single-package COPR, upstream Rust builds for f43–rawhide)
- **Zed**: Flathub Flatpak `dev.zed.Zed` (system-wide install, requires hardware Vulkan driver; Fedora-built RPMs freeze on F44 due to GCC 16/LLVM ABI bug rhbz#2464281, unresolved; updates via `flatpak update`)
- **Spotify**: Firefox webapp with Widevine (replaces the `com.spotify.Client` Flatpak; downloads the Widevine CDM on first launch)
- **Bazaar**: Flathub Flatpak `io.github.kolunmi.Bazaar`, the store for GUI apps you install yourself (see [Installing your own software](#installing-your-own-software))
- **Signal, OBS Studio, Obsidian**: Flathub Flatpaks (system-wide install, `VEKRONA_FLATPAKS`; Obsidian is closed source but has no web version and works on local vault files)
- **Syncthing**: Fedora repository (the `syncthing` RPM runs as your user service `syncthing.service`; it has no web GUI and no TCP GUI port: its GUI and REST API listen on the unix socket `/run/user/<uid>/syncthing/gui.sock`, which only your user can open, so you need no login)
- **Proton Mail (with Calendar), Pass and Authenticator**: native apps from Proton's own feeds (see [updates](updates.md))
- **Telegram, Discord, SoundCloud, YouTube, WhatsApp**: Firefox webapps (Spotify above; `vekrona-webapp <app>` starts one, the full list is under Daily operations)
- **Steam**: RPM Fusion (already installed; stage 60 sets Steam Play preset to `proton_experimental` for all titles)
- **Tailscale**: Fedora `updates` repository (no vendor repo needed; `tailscaled` enabled and active, you are operator: `tailscale up` without sudo; shields up and Tailscale SSH off, so nothing on the tailnet can connect in (what this breaks: another node cannot start a Syncthing connection to this one, receive a Taildrop file here, or open a Steam Remote Play session to this machine over the tailnet; connections this machine starts work as before): stage 40 sets them and a `tailscaled` drop-in sets them again at every start, because tailscaled keeps no setting across a restart until the node is logged in; so the first login is `tailscale up --shields-up --ssh=false` (without the flags it refuses, because they differ from the defaults); no tray icon: manage it from the CLI with `tailscale status`, `tailscale up` and `tailscale down`)
- **btop**: Fedora repository
- **Non-free codecs**: RPM Fusion (swap `ffmpeg-free` to `ffmpeg`, add freeworld gstreamer plugins, `mesa-va-drivers-freeworld`, openh264 via already-enabled `fedora-cisco-openh264`; VDPAU packages no longer exist in F44)

## Installing your own software

- GUI apps: open Bazaar from the launcher, or run `flatpak install flathub <id>`. Both install system-wide, because vekrona has
  only the system Flathub remote and `vekrona-update` updates system Flatpaks only; do not use `--user`.
- Everything else: `sudo dnf install <package>`; `dnf upgrade` keeps it current.
- Stage 30 keeps an unwanted package that a package you installed depends on, and reports it ([details](#packages-vekrona-removes)).

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

Stage `30-packages` installs `firewalld` and stage `40-system` enables and starts it, then `ensure_default_zone` (`lib/firewall.sh`)
makes `public` the default zone. Fedora Workstation's own default, `FedoraWorkstation`, accepts every TCP and UDP port from 1025 up
from the local network. `public` holds exactly what vekrona runs and nothing else, services all of them and no port: `dhcpv6-client`,
`syncthing` (22000/tcp and udp, 21027/udp for local discovery; its GUI is a unix socket, no port), `steam-streaming` and
`steam-lan-transfer` (Steam is installed by stage 30: Remote Play and local game transfer). Whatever else the zone holds, stock
`ssh` and `mdns`, a port opened by hand or by an earlier vekrona (AirPlay's 6001-6010), a protocol, source port, forward port,
rich rule, masquerading or a target other than `default`, the stage removes again, and it reloads firewalld when the running
configuration differs from the permanent one. Stage 40 reports, and stage 70 fails on, a zone with an interface that opens every TCP port
from 1025 or whose target is `ACCEPT` (`trusted`, or a zone that libvirt or Docker made). A new service is one
more word in `DEFAULT_ZONE_SERVICES` (`lib/firewall.sh`). If a NetworkManager connection is pinned to the `FedoraWorkstation` zone
(`nmcli -f connection.zone connection show <name>`), stage 40 reports it and `70-verify` fails until
`nmcli connection modify <name> connection.zone ''` clears the pin.

There is no sshd: stage 30 removes `openssh-server`, and stage 40 deletes the sshd drop-in, the `tailnet` firewall zone and the ssh
reject rules that earlier installs left. Tailscale runs with shields up and Tailscale SSH off. AirPlay is gone too: `avahi`,
`nss-mdns` and `pipewire-config-raop` are removed, the authselect profile no longer selects `with-mdns4`, and
`/etc/systemd/resolved.conf.d/50-vekrona.conf` turns LLMNR and mDNS off in systemd-resolved, so nothing listens on 5353 or 5355. The
vekrona-dev VM and the ISO test guest are the exception: they carry the marker `/etc/vekrona/keep-sshd`, which keeps `openssh-server` and
the `ssh` service of the zone ([development](development.md)).

### Packages vekrona removes

Stage `30-packages` removes what a Fedora Workstation install carries and vekrona never uses (`VEKRONA_UNWANTED_PKGS`,
`lib/common.sh`; stage 70 checks each one is gone): the crash reporter (`abrt`), `avahi`, printing and scanning (`cups`,
`cups-browsed`, `cups-filters`, `hplip`, `gutenprint`, `system-config-printer`, `ipp-usb`, `sane-backends`), mobile broadband and DSL
(`ModemManager`, `NetworkManager-wwan`, `NetworkManager-adsl`), `blueman` and `network-manager-applet` (the shell has its own network and Bluetooth panels), `sssd`, `PackageKit`, `rsyslog`, `nfs-utils` and `at`, and with them
whatever requires them. Losing `NetworkManager-bluetooth` ends Bluetooth tethering (PAN and DUN); headsets and other Just Works
devices still pair from the shell, but a device that asks for a PIN or passkey (a keyboard, some phones) needs `bluetoothctl` until the
shell registers its own pairing agent (`blueman` provided the only one): run `bluetoothctl`, then `agent on`, `default-agent` and
`pair <MAC>`. A Wi-Fi hotspot on the phone is the usual way to share its connection. The machine does
not print: there is no CUPS. `iscsi-initiator-utils` stays because `libvirt-daemon-kvm` requires it; its sockets start only on use.

Stage 30 never removes a package you chose, for the packages above and for the retired ones (`VEKRONA_RETIRED_PKGS`, same path).
It treats as chosen what `dnf` records with the install reason `User` (`dnf install`, `dnf mark user`; see them with
`dnf repoquery --installed --qf '%{name} %{reason}\n'`). `External User` does not count: dnf gives it to any package it has no
record of, plain dependencies included. The packages on the lists above go even when you installed them. When a package you chose
needs one of them (directly or through dependencies), stage 30 keeps that package, removes the others, and prints a warning that
names what holds it; stage 70 prints the same warning instead of failing. The warning repeats on every run until you remove the
holder, or the unwanted package and the holder together. Packages that only came with the installer's groups (reason `Group`) or as
dependencies do not count as chosen, and a vekrona desktop package that would be removed along is an error of vekrona, which stops
the stage. Stage `90b-remove` (run by name) is different: it removes the GNOME and KDE leftovers it lists (`gnome-software`,
`xdg-desktop-portal-gnome`, `xdg-desktop-portal-kde`, `gnome-remote-desktop`) whatever their install reason.

### Kernel hardening

Stage `40-system` installs `/etc/sysctl.d/60-vekrona.conf` and `/etc/modprobe.d/vekrona-hardening.conf` ([threat model](threat-model.md)).
What you notice: `dmesg` needs `sudo` (`journalctl -k` does not), `gdb -p` and `strace -p` on a process that is not your child
need `sudo`, and a FireWire controller does not work.

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
lock screen), so the generated file is output, never input. The shell reloads it on every write, so `vekrona-theme`
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

Super+Shift+3/4/5 work like Cmd+Shift+3/4/5 on macOS, and adding Ctrl copies to the clipboard without saving a file. In area mode, click a window or drag a rectangle; area and window mode close an open tray menu first, which would otherwise stay on top of the selection, and screen mode captures it. Saved shots are also copied to the clipboard, and the notification has Edit (opens swappy) and Delete (moves the shot to the trash) buttons.

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
`config/scopebuddy/scb.conf` (`-f`, plus the width, height and refresh rate of the focused output, read from Sway at launch):

```
scb -- %command%
```

MangoHud toggle in-game: Shift_R+F12 (`config/mangohud/MangoHud.conf`,
`toggle_hud=Shift_R+F12`).

## VPN

The bar's VPN icon opens a popout: pick a vendor, then a country (and, where a country has several configurations, one of them).
Mullvad: enter your account number once, then every country is one click and each connect uses a random relay there. Proton or any
other provider: download a WireGuard `.conf` from the provider, use Import Proton… or Import other… (only the popout imports), and
name the country in the file name (`NL-792.conf`) so the list can group it. Off turns the tunnel and the kill switch off.

Settings, VPN in the launcher shows the same connections as one flat list, with Turn the VPN off as its first row: every Mullvad
country and every imported configuration is a row of its own, and Enter connects. It has no account field and no Import, so while
Mullvad has no account it lists no Mullvad countries at all; log in from the bar's popout first.

The kill switch is the point: once you connect, anything that does not go through the tunnel is rejected until you press Off, so a
tunnel that drops shows the blocked icon and stops your programs instead of leaking. The same commands work from a terminal
(`vekrona-vpn status`, `connect`, `off`). What the kill switch lets through, and the rest: [vpn](vpn.md).

## Sync

Sync keeps folders the same on all your devices, and sends a file to one of them. It is Syncthing underneath, but there is no web
page and no folder IDs to handle: the bar's Sync icon opens the list, and the commands below do the same from a terminal. Everything
is between devices you accepted yourself; there is no server.

**Add a device.** Three ways, all from the Sync list.

- *Nearby.* A device on the same network that runs Syncthing announces itself (local discovery), and shows up under "Nearby" as
  "Syncthing device ABCD-EFG" (its code, the first characters of its device ID). Press Pair: this computer adds it and offers it
  every folder. It then asks on its side, "<this computer> wants to connect", and is *online* under "My devices" as soon as you
  accept there. Syncthing never forgets a device it heard, so a device is nearby only while one of the addresses it announced on the
  local network (a private or link-local IP address) accepts a connection. The watcher tries a device's addresses when Syncthing
  reports it on the network (when it first appears, after 90 s of silence, or when its Syncthing restarts), and the shell tries
  those of every listed device each time the list opens, one second at most, and shows the ones that answer; `vekrona-sync nearby`
  prints them. The list holds the 16 devices that Syncthing reported last.
  You do not have to look: when such a device appears and answers, a notification asks "A Syncthing device ABCD-EFG is nearby.
  Pair with it?" with Not now, Pair and Ignore, once per device for good (a device that goes away and comes back, or a restart of
  Syncthing or of the watcher, does not ask again; the ledger is kept in `~/.local/state/vekrona/sync-ledger.json`). Not now leaves the device under Nearby,
  with a dot on the bar's Sync icon until the list shows it (it shows a device that answers when the list opens); Ignore is the same as Reject (the device is ignored for good). Pair,
  here or anywhere else, says "Pair request sent to ABCD-EFG", and once the other device accepts and connects, "<name> is now
  one of your devices".
- *Not nearby.* "Pair another device…" shows this computer's device ID as text (Copy ID puts it on the clipboard) and as a QR code
  that the Syncthing app of a phone scans, and has a field for the other device's ID: paste or type it (any case, with or without
  dashes), then Pair or Enter. A wrong ID is refused with Syncthing's reason under the field.
- *The other device adds this computer first.* This computer then shows a notification, "<name> wants to connect", with the short
  code, and "New devices" in the list: check that the code starts the same as the device ID on the other device, then press Accept.
  Reject ignores the device for good, so it neither asks nor shows up under Nearby again; pairing it on purpose later (its ID in
  the field) takes it off that list.

The device is then one of *your devices*: every folder you share goes to all of them, and a folder you join is shared on with all
of them. Ignoring a request adds nothing.

Syncthing shows a device's folders only when that device offers them, and the Mac and Android apps offer none by themselves: a
connected device that no folder of this computer lists and that offers none says "Shares no folders with this computer yet. Share them
from its Syncthing app." under its name in My devices. Open the app on that device, share a folder with this computer, and the
offer shows up under "Offered to you".

```
vekrona-sync id
vekrona-sync qr
vekrona-sync pair DEVICE_ID [NAME]
vekrona-sync accept DEVICE_ID
vekrona-sync reject DEVICE_ID
```

**Share a folder.** "Share a folder…" in the Sync list opens a folder chooser, and then the list comes back with the folder's ID to
confirm: Enter or Share offers the folder to your other devices, Esc or Cancel shares nothing. The folder stays where it is on this
computer. A folder that holds a shared folder or sits inside one is refused, since Syncthing would sync its files twice, and so are
your home directory and any other folder that holds Syncthing's own directory (`~/.local/state/syncthing`, with its keys) or the
hidden folders of Send file; the same goes for the path that Join is given.

The ID is suggested from the folder's name in lowercase with dashes (`My Notes` is `my-notes`; accents are folded, `Café` is
`cafe`; a name that already has a folder here gets `-2`). A name with letters that ASCII cannot spell (`Фото 2024`), or none
(`..`), gets a random ID such as `3fa9c-01b7e`, because half a name would mislead, and you can type your own. An ID has lowercase
letters and digits with single dashes between them, at most 64 characters, and does not start with `vekrona-drop-`; a refused ID
says why under the field.

Choose the ID with care. It is fixed once the folder is shared, because Syncthing cannot rename it. The ID is how devices tell
that they mean the same folder: when two devices share a folder under the same ID, it is one folder, and their files merge. The label (the folder's name on screen, which defaults to the directory's name) is what can differ between devices.

```
vekrona-sync choose-folder
vekrona-sync suggest-id ~/Documents/notes
vekrona-sync share ~/Documents/notes
vekrona-sync share ~/Documents/notes --id notes
```

**Join a folder.** A folder another device shares shows under "Offered to you" and in a notification. Join puts it at
`~/Sync/<its name>`. Join refuses a folder that would land in a directory that already has files; give it another path then. A folder that exists on
this computer already (the same ID) is not joined again: Join shares it with the device that offers it.

```
vekrona-sync join FOLDER_ID ~/somewhere/else
```

**Send a file.** "Send file…" on a device's row opens a file chooser. The file lands in that device's Downloads folder with a
notification, right away if the device is online, otherwise as soon as it is. A name that is taken there gets a number: `photo.jpg`
becomes `photo (2).jpg`, and nothing is ever overwritten. This computer does the same for files that arrive: they go to your Downloads
folder (the one `xdg-user-dir DOWNLOAD` names), with a notification, and the Sync icon shows a dot until you open the list.

```
vekrona-sync send DEVICE_ID photo.jpg report.pdf
```

Sending needs both devices to run vekrona. Under the hood the two devices share a hidden folder, `vekrona-drop-<id>-<id>`, in
`~/.local/share/vekrona-sync/drops/`, which each accepts from the other without asking; it holds the files that are on their way, and
a file leaves it once it is in Downloads. Another Syncthing client (Android, macOS) sees that folder as an ordinary shared folder
and never empties it, so a file sent to such a device stays on that device in the folder's `to/<device ID>/` directory, where
`<device ID>` is the long ID of that device. When its Syncthing asks about the folder "vekrona drop", accept it and set its
path to a folder you will find in the device's file app, for example `Download/vekrona-drop` on a phone: the files arrive in
`Download/vekrona-drop/to/<the phone's ID>/`. This computer's own copy of such a file does not stay: once the device has the
file, this watcher adds the file's path to the `.stignore` of the drop (Syncthing then keeps the device's copy and no longer
treats this computer's as a file to sync), deletes its copy, and removes the line when the device deletes its copy. The `.stignore`
of a drop therefore holds one line per file that a keeping device still has; a name that has a line is not reused, so sending
`photo.jpg` again becomes `photo (2).jpg` while the device still has the first one. A device that is not one of
the two cannot join the folder: its offer of a drop is ignored (a line in the journal of `vekrona-sync.service`), and a drop folder
that a third device shares in Syncthing is neither sent through nor received from until you remove that device from it.

What the icon shows: the two round arrows of Material's `sync`, still when idle and turning in steps (four a second, only while something syncs and somebody is there: it stops after 300 s without input, when the screen locks, and goes on at the next input) while syncing, with a warning mark for a problem (the list gives the reason in words), and struck through when offline (Syncthing is not running). `vekrona-sync watch`
is the service behind it, and `systemctl --user status vekrona-sync` shows how it is doing. It wakes only when Syncthing reports a
change, and while Syncthing does not answer it is started again after a longer wait each time, up to a minute. When the list says
"The sync service is out of date", the service still runs code from before an update of the checkout: restart it with
`systemctl --user restart vekrona-sync`, or run `./install.sh 50`, which restarts it.

## The Desktops widget

The shell's Desktops widget (`config/vekrona-shell/Desktops.qml`) always shows
desktops 1-5, even empty, plus any desktop 6-10 that currently exists, because
Sway deletes an empty workspace as soon as you focus away from it. Click a
desktop to switch (`workspace number N` over the Sway IPC socket via
`Quickshell.I3`), scroll over the widget to step through the shown desktops.
Focused, occupied (has a window) and urgent desktops use the `accentInk`,
`ink` and `dangerInk` tokens; the focused one also gets the `selected` fill.
