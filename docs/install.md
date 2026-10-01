# Installing vekrona

Reference for the install routes and the stage runner. The [README](../README.md#how-to-install) has the short version.

## Fresh install on Fedora minimal

Prerequisites:

- Fedora Linux 44, installed from the Everything netinstall with only `@core`
  selected: text console, `multi-user.target`, no desktop, no display
  manager.
- Network access.
- Btrfs root subvolume, with `/boot` on its own filesystem (the installer's default layout;
  nothing checks it, and `bin/vekrona-rollback` only warns when `/boot` holds
  a kernel the restored root has no modules for). Stage
  `20-snapper` and `bin/vekrona-rollback` assume btrfs and snapper.
  The root subvolume must be named `root` (`vekrona-rollback` renames and
  replaces it), and `/home` must be a subvolume on the same Btrfs filesystem
  (stage `20-snapper` mounts the `nix` subvolume from the device `/home`
  uses).
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
`00-repos 20-snapper 10-nvidia 15-mac 30-packages 40-system 45-auth 50-user 55-agents 60-gaming 65-login-manager 70-verify`
(on a Mac, `10-nvidia` is skipped; on non-Mac hardware without NVIDIA, both `10-nvidia` and `15-mac` are skipped; `55-agents` runs everywhere).
Snapper runs before NVIDIA so a snapshot exists before stage `10-nvidia` touches
the driver. Stage `65-login-manager` runs last, after everything that
installs and configures greetd (`30-packages`, `40-system`) and right before
verify: on a fresh install nothing owns `display-manager.service` yet, so it
enables greetd and switches the default target to `graphical.target`. See
[New default stage: 65-login-manager](#new-default-stage-65-login-manager) for the exact condition. Stage
`55-agents` installs the coding-agent harnesses (Claude Code, Codex, OpenCode,
Pi, Cursor); see [Agents: delivery and updates](agents.md#agents-delivery-and-updates).

Reboot, then log in through the greeter (tuigreet, running `start-sway`).

## Install from ISO

Instead of installing plain Fedora minimal by hand and cloning this repo
yourself, `iso/build.sh` bakes both into a Fedora 44 Everything netinstall
ISO, plus two small Anaconda add-ons (`iso/anaconda/updates/`, shipped as an
`updates.img`) that replace Anaconda's own user-creation, root-password and
time & date screens with two screens at the top of the hub:

- **VEKRONA ACCOUNT**: **full name** (optional), **username** and
  **hostname** (default `vekrona`), and the **time zone**, a type-to-search
  field (e.g. typing "berlin" narrows to `Europe/Berlin`) defaulting to
  whatever Anaconda's own geolocation already resolved, or UTC if that is
  unavailable. The account is always an administrator (`wheel`); root is always
  locked, with no root password to set.
- **VEKRONA SIGN-IN**: the **password** (typed twice). This one password
  becomes both the account password and the disk encryption passphrase, so
  there is no separate LUKS passphrase to remember. A security key and a
  fingerprint reader can be enrolled here too (see [Sign-in methods](sign-in.md)).

Anaconda itself still handles everything storage- and network-related:
**Installation Destination** always needs a visit (disk selection, reclaim
space for dual-boot). Custom and Blivet-GUI partitioning are hidden, because
the disk must end up as btrfs on LUKS2 with the sign-in password. The sign-in
screen verifies the layout Anaconda actually applied and, when it is not
encrypted with that password, re-applies an encrypted automatic partitioning
itself, so the standard "Disk Encryption Passphrase" dialog is not needed.
**Network & Host Name** (including Wi-Fi) is Anaconda's own screen, unchanged.

The ISO sets no language or keyboard layout, so Anaconda shows its Welcome
language screen and picks defaults from the network location when it can
(the boot entries pass `inst.geoloc-use-with-ks`, because Anaconda otherwise
skips geolocation whenever a kickstart is present). The **Keyboard** screen
therefore needs one visit to confirm the layout. The installed desktop follows
the layouts chosen there (with several, Left Alt + Right Alt switches between
them); see [Keyboard](keyboard.md) for how, and how to change them later.

Once the install finishes and the machine reboots, the disk prompt will ask for
that same password (or the security key, if you registered one) to unlock the
encrypted root before vekrona's first-boot
service (`vekrona-firstboot.service`) copies the checkout baked into the ISO
to `~/vekrona` in the new user's home and runs `./install.sh`
unattended, ending at the same greetd login prompt. See [ISO and CI](development.md#iso-and-ci)
for how the ISO and addon are built, what first boot does, and how it is
tested.

## Stage semantics

- Name a stage by its number prefix, its name suffix, or its full name: `./install.sh 30`, `./install.sh packages`, and `./install.sh 30-packages` all run the same stage.
- `--skip STAGE` drops one stage from the run, and also drops it from the set that `70-verify` checks.
- Pass explicit stage names to run a subset, for example `./install.sh 10 30` (used later to re-lock package versions after a Fedora upgrade, see [Update policy](updates.md)).
- `90a-switch-dm` and `90b-remove` never run by default; name them explicitly, e.g. `./install.sh 90a-switch-dm`.
- `--reset-dms-settings` overwrites `~/.config/DankMaterialShell/settings.json` from the seed file. Without it, an existing `settings.json` is left alone on every re-run, so DMS settings changed by hand survive a re-run of stage `50-user`. This flag only resets `settings.json`. The separate DMS session file, `~/.local/state/DankMaterialShell/session.json`, is seeded whenever it is absent regardless of this flag, and is never overwritten once it exists, even by `--reset-dms-settings`.
- Each stage starts with `sudo -v`, so expect one password prompt per stage. There is no background loop refreshing the sudo timestamp mid-stage, so a long stage can prompt again partway through.
- Every stage is written to be idempotent: the `ensure_*` helpers in `lib/common.sh` check the current state before changing anything, so re-running `./install.sh` after a partial or failed run only touches what is still missing.
- `ensure_symlink` never overwrites a real file silently. If the symlink target already exists and is not itself a symlink, it gets moved to `<target>.pre-vekrona` first. If that backup path is already taken, the stage fails instead of picking a second name, because a second collision at the same path usually means an earlier conflict was never resolved by hand.

## New default stage: 65-login-manager

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
