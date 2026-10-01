# vekrona

My Fedora desktop as a shell script: Sway and DankMaterialShell on Fedora 44,
with Btrfs snapshots, a Mac-style keyboard and Steam.
Website: [vekrona.com](https://vekrona.com/)

[![Video tour of the vekrona desktop: workspaces, launcher, panels, theme switch, the verify stage, lock screen](https://vekrona.com/assets/video/poster.webp)](https://vekrona.com/assets/video/vekrona-promo.mp4)

A 61-second tour, no sound, captions on screen. Click the picture to play it.

## Why

I want a desktop I can rebuild from scratch and update without fear.

- **Repeatable.** `./install.sh` turns a minimal Fedora install into the whole
  desktop. Each stage checks the current state before it changes anything,
  so after a failure you fix the cause and run it again. The last stage,
  `70-verify`, checks the result.
- **Safe to update.** Snapper takes a snapshot before and after every dnf
  transaction. `sudo vekrona-rollback <N>` makes snapshot N the root again.
  Sway, DMS, Quickshell, Qt and the NVIDIA driver are version-locked, so a
  routine `dnf upgrade` leaves them alone.
- **Looks good.** Sway tiles, DankMaterialShell draws the bar, launcher and
  panels. Four themes (Tokyo Night, Catppuccin Mocha, Gruvbox Dark, Nord)
  switch the shell, GTK apps, the terminal and the wallpaper together.
- **Keyboard.** Caps Lock is Esc when tapped and a Hyper key when held.
  Hyper plus a key switches workspaces, moves windows and opens the shell's
  panels. Outside terminals, Super works like Cmd on a Mac: Cmd+C,
  Cmd+Z, Cmd+Left. Terminals keep Ctrl for the shell.
- **Games.** Steam with Proton on for every title, gamescope through
  ScopeBuddy, MangoHud and GameMode.

It is built for my desktop (Ryzen 7950X3D, RTX 4090, Dell AW3225QF at 4K and
240 Hz) and shared as it is. Stage `15-mac` adds support for 2013–2015 MacBook Pros;
that part has not been tested on real hardware yet.

## What

vekrona is a recipe. It installs and configures software other people build:

| | |
|---|---|
| Base | [Fedora Linux](https://fedoraproject.org/), [RPM Fusion](https://rpmfusion.org/) for codecs, Steam and the NVIDIA driver |
| Desktop | [Sway](https://swaywm.org/) on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots), [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell) on [Quickshell](https://quickshell.org/), [matugen](https://github.com/InioX/matugen), [rofi](https://github.com/davatorium/rofi) |
| Terminal and keyboard | [Ghostty](https://ghostty.org/), [xremap](https://github.com/xremap/xremap) |
| Login and filesystem | [greetd](https://sr.ht/~kennylevinsen/greetd/) with [tuigreet](https://github.com/tuigreet/tuigreet), [Btrfs](https://btrfs.readthedocs.io/en/latest/), [snapper](https://github.com/openSUSE/snapper), [pam-u2f](https://github.com/Yubico/pam-u2f) and [fprintd](https://fprint.freedesktop.org/) for security keys and fingerprints |
| Gaming | [Steam](https://store.steampowered.com/), [ScopeBuddy](https://github.com/OpenGamingCollective/ScopeBuddy), [gamescope](https://github.com/ValveSoftware/gamescope), [MangoHud](https://github.com/flightlessmango/MangoHud), [GameMode](https://github.com/FeralInteractive/gamemode) |
| Apps | [Firefox](https://www.firefox.com/) (YouTube, WhatsApp and Spotify run as Firefox web apps), [Zed](https://zed.dev/), [1Password](https://1password.com/), [Tailscale](https://tailscale.com/), [Nix](https://nixos.org/) with [devbox](https://www.jetify.com/devbox), [btop](https://github.com/aristocratos/btop), [herdr](https://herdr.dev/) |
| Coding agents | [Claude Code](https://github.com/anthropics/claude-code), [Codex](https://github.com/openai/codex), [OpenCode](https://github.com/anomalyco/opencode), [Pi](https://github.com/earendil-works/pi), [Cursor CLI](https://cursor.com/cli), the last four installed with [mise](https://mise.jdx.dev/) |
| MacBook | [facetimehd](https://github.com/patjak/facetimehd) camera driver |
| Fonts | [JetBrainsMono Nerd Font](https://www.nerdfonts.com/), [Atkinson Hyperlegible Next](https://www.brailleinstitute.org/freefont/), [Inter](https://rsms.me/inter/) |

The install creates a local user and asks you to sign up for nothing. Steam,
Spotify, WhatsApp, 1Password, Tailscale and the coding agents need their own
accounts. Claude Code and Codex are locked to subscription logins; the
launcher removes API-key variables for all agents
([details](docs/agents.md#subscription-only-enforcement-per-tool)).

## How to install

### On a minimal Fedora install

You need:

- Fedora 44 installed from the
  [Everything netinstall](https://fedoraproject.org/misc/#everything) with only
  `@core` (Minimal Install) selected.
- A Btrfs root on a subvolume named `root`, `/home` on a subvolume of the same
  filesystem, and `/boot` on its own filesystem (the installer's default layout).
- Network access, and a user with sudo. `install.sh` refuses to run as root.

Then:

```
sudo dnf install -y git
git clone https://github.com/vekrona/vekrona ~/wrk/vekrona
cd ~/wrk/vekrona
./install.sh
```

Reboot and log in at the greeter. `./install.sh --list` shows the stages that
apply to your machine: `10-nvidia` runs only with an NVIDIA GPU outside a Mac,
`15-mac` only on a Mac.

On hardware other than mine:

- `10-nvidia` installs the proprietary driver and sets kernel arguments chosen
  for my RTX 4090. Read the stage first, or run `./install.sh --skip 10-nvidia`.
- Change the `output DP-7` line in `config/sway/config` and the 3840x2160,
  240 Hz in `config/scopebuddy/scb.conf` to match your monitor.
- On a MacBook Pro, read [the MacBook notes](docs/macbook.md) first: with
  the BCM4360 Wi-Fi chip you need Ethernet or USB tethering until stage
  `15-mac` has built the driver and you have rebooted.

### From the installer ISO

`iso/build.sh` builds a Fedora 44 netinstall ISO with this repo inside and two
extra installer screens: one for your account, host name and time zone, one
for the password. That password unlocks both your account and the disk, which
is Btrfs on LUKS2. The same screen can enroll a security key or a fingerprint
reader ([sign-in methods](docs/sign-in.md)). On first boot the machine runs
`./install.sh` by itself and reboots into the greeter. How to build it:
[ISO and CI](docs/development.md#iso-and-ci).

## More

- [Installing](docs/install.md): stage order, `install.sh` flags, the ISO in detail
- [Sign-in methods](docs/sign-in.md): security key, fingerprint, password
- [MacBook Pro 2013–2015](docs/macbook.md)
- [Migrating an existing Fedora Workstation](docs/migration.md)
- [Keyboard](docs/keyboard.md): every binding and the Cmd layer
- [Daily use](docs/daily-use.md): apps, themes, screenshots, snapshots and rollback
- [Update policy](docs/updates.md)
- [Coding agents](docs/agents.md)
- [Error pipeline](docs/errors.md)
- [Known issues](docs/known-issues.md)
- [Development](docs/development.md): repo layout, tests, VM smoke test, ISO build, CI
- [Design record](docs/PLAN.md)

MIT licensed, see [LICENSE](LICENSE). The vendored fonts are under the
[SIL Open Font License](fonts/OFL.txt).
