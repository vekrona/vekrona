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
| `stages/*.sh` | one script per stage, numbered so the run order is visible in a directory listing |
| `config/` | source of truth for dotfiles; stage `50-user` symlinks these into `$HOME`. Stage `50-user` also generates `~/.config/environment.d/vekrona-gpu.conf` itself, not tracked under `config/`, only when `/dev/dri/vekrona-dgpu` exists (see Known issues) |
| `etc/` | system files installed into `/etc` by `ensure_root_file` |
| `bin/vekrona-*` | the CLI tools; stage `50-user` symlinks the whole directory into `~/.local/bin` |
| `config/systemd-user/vekrona-errors.service`, `vekrona-errors-failed.service` | `vekrona-errors.service` runs `vekrona-error watch` (the error pipeline, see "Error pipeline" below); `vekrona-errors-failed.service` is its `OnFailure=` notifier. Stage `50-user` links and enables them the same way it does `xremap.service` |
| `config/agents/skills/vekrona-diagnose/` | the Claude Code skill an agent uses to investigate a vekrona error; stage `50-user` symlinks it into `~/.claude/skills/`, `~/.codex/skills/`, and `~/.agents/skills/` |
| `fonts/` | vendored JetBrainsMono Nerd Font (OFL, v3.5.1), symlinked into `~/.local/share/fonts/vekrona` |
| `config/fontconfig/conf.d/50-vekrona-fonts.conf` | fontconfig aliases: `sans-serif`/`system-ui` prefer Atkinson Hyperlegible Next then Inter (Atkinson has no Cyrillic, Inter covers it), `monospace` prefers JetBrainsMono Nerd Font; symlinked into `~/.config/fontconfig/conf.d/` |
| `config/DankMaterialShell/plugins/vekronaSwayWorkspaces/` | DMS DankBar plugin: always shows Sway workspaces 1-5 plus any existing 6-10, replacing the stock workspace switcher (see "The vekronaSwayWorkspaces DankBar plugin" below); stage `50-user` symlinks the whole `plugins/` directory into `~/.config/DankMaterialShell/plugins/` |
| `config/DankMaterialShell/plugins/vekronaAgent/` | DMS DankBar plugin: agent-button icon with an unread-error badge, left click opens the default coding agent, right click opens the recorded-error picker (see "Agent button" below) |
| `bin/vekrona-agent` | opens a configured coding agent harness (Claude Code, Codex, opencode, pi, or Cursor Agent) in a terminal, with default permission prompts and API-key env vars stripped; see "Agent button" below |
| `bin/vekrona-rofi-theme` | prints a `rofi -theme-str` string from the active vekrona/DMS theme; shared by `vekrona-keybindings` and `vekrona-agent` so the rofi styling lives in one place |
| `vm/` | libvirt smoke-test harness: Makefile, kickstart, session, agents, error-pipeline, agent-launch, rollback, and login-manager checks |
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
`00-repos 20-snapper 10-nvidia 30-packages 40-system 50-user 55-agents 60-gaming 65-login-manager 70-verify`.
Snapper runs before NVIDIA so a snapshot exists before stage `10-nvidia` touches
the driver. Stage `65-login-manager` runs last, after everything that
installs and configures greetd (`30-packages`, `40-system`) and right before
verify: on a fresh install nothing owns `display-manager.service` yet, so it
enables greetd and switches the default target to `graphical.target`. See
"New default stage: 65-login-manager" below for the exact condition. Stage
`55-agents` installs the coding-agent harnesses (Claude Code, Codex, OpenCode,
Pi, Cursor); see "Agents: delivery and updates" below.

Reboot, then log in through the greeter (tuigreet, running `start-sway`).

### Install from ISO

Instead of installing plain Fedora minimal by hand and cloning this repo
yourself, `iso/build.sh` bakes both into a Fedora 44 Everything netinstall
ISO: Anaconda still asks for a disk and a user (btrfs autopart preset), then
a first-boot service clones this repo to the new user's home and runs
`./install.sh` unattended, ending at the same greetd login prompt. See "ISO
and CI" below for how the ISO is built, what first boot does, and how it is
tested.

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
| Hyper+a | open the coding agent (`vekrona-agent --pick`) |
| Hyper+Shift+a | pick a recorded error and open the agent on it (`vekrona-error pick`) |
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

## Error pipeline

Every error on the machine lands in one place, so any of them can launch a
coding agent to go diagnose it. `vekrona-errors.service` (a user unit, like
`xremap.service`, `WantedBy=sway-session.target`) runs `vekrona-error watch`,
which follows the journal and turns four kinds of entry into a recorded error:

- a coredump (`systemd-coredump`, any crashing process)
- a failed systemd unit, system or user (it reads the *system* journal, which
  a `wheel` member can read in full and which already includes user units'
  own entries, so one watcher covers both without needing the
  `systemd-journal` group)
- a kernel OOM kill, or a `systemd-oomd` kill
- any other journal entry logged at priority `err` or above

`vekrona-error report --title T [--summary S] [--source vekrona|manual]` adds
a fifth kind by hand: it writes one structured entry straight to
`/run/systemd/journal/socket` in journald's own native protocol (no `logger`
dependency, and multi-line summaries survive intact), so it works as root,
with no session bus, and before `python3-gobject` is even installed.
`lib/common.sh`'s `die()` calls it
this way on every stage failure, and `vekrona-keybindings`' own `die()` does
the same, so a broken stage or a failed keybinding shows up here too instead
of (or as well as) wherever it already prints to. If the system journal isn't
readable at all (not in `wheel` or `systemd-journal`), the watcher sends one
critical toast saying so and falls back to the user journal only.

Each error is recorded once under
`~/.local/state/vekrona/errors/<id>/` (`record.json` plus a `context.txt`
captured at the time: the relevant `journalctl`/`systemctl status`/
`coredumpctl info` output; a corrupt `record.json` is quarantined to
`record.json.corrupt` rather than crashing the watcher or the CLI). Repeats of
the same error (by a fingerprint that normalizes out digits, hex, paths, and
UUIDs from the message) bump its count instead of creating a new record. A
repeat within 10 minutes of the last one doesn't re-toast, *unless* the record
had been `ack`ed (or launched) since the last occurrence, in which case it
re-toasts regardless of the window — an acked error recurring is exactly what
acking is supposed to surface again. `~/.local/state/vekrona/errors/unread`
holds the count of errors still in `new` status, kept for the DMS bar button
(added by another stream) to read. The newest 500 records, by `last_seen`, are
kept; older ones are pruned.

A toast (via DMS's notification daemon) has two actions, "Fix with agent" and
"Mute" (clicking the toast body does the same as "Fix with agent": stage
`50-user` enforces DMS's own `notificationPopupBodyInvokesAction` setting to
`true` in `settings.json`, since DMS defaults it to `false` and otherwise only
dismisses the popup on a body click rather than running its first action;
`70-verify` asserts it stays `true`. This is a DMS-wide setting, not specific
to vekrona's own toasts: a body click on *any* application's notification
popup runs that notification's first action the same way, once this is set):
the former launches `vekrona-agent --pick --error <id>` as a monitored child (its failure
or non-zero exit is itself toasted, not swallowed), the coding agent launcher
built by another stream, which calls `vekrona-error prompt <id>` to get its
brief (see `config/agents/skills/vekrona-diagnose/SKILL.md`, symlinked into
`~/.claude/skills/`, `~/.codex/skills/`, and `~/.agents/skills/`) and marks the
record `launched`; the latter appends the error's fingerprint to
`~/.config/vekrona/errors-mute` (one regex per line, matched against both the
fingerprint and the title; an unparseable line is toasted once by name rather
than silently ignored) and marks it muted, so a matching error is dropped
silently from then on, no record, no toast. More than 5 toasts within 30
seconds collapse into one "N new errors" toast instead, whose action opens a
picker rather than any single error. The watcher remembers which notification
id belongs to which error only while the same notification daemon (D-Bus
owner) that issued them is still running; if it restarts (or clicking a
notification racing a watcher restart), the action is answered with a small
"this notification is stale; use Hyper+Shift+A" toast instead of being
silently dropped.

```
vekrona-error list [--all]     # table of recorded errors, newest first (--all includes muted)
vekrona-error show <id>        # one error's record plus its captured context
vekrona-error mute <id>        # mute this error's fingerprint
vekrona-error ack <id>|--all   # mark handled
vekrona-error rm <id>          # delete one error's record outright (not mute: it can come back on a repeat)
vekrona-error pick             # rofi picker (bound to Hyper+Shift+A by another stream) -> launches the agent on the pick
```

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

## Agents: delivery and updates

Five coding-agent CLIs run on this desktop, each launched by name from Sway
(the launcher itself is a separate concern from this repo): Claude Code,
Codex, OpenCode, Pi, and Cursor. All five are subscription-login tools; no
API keys are configured or stored by vekrona. Stage `55-agents` installs
them through exactly two package managers, so there is no per-tool lockfile
or hash management to maintain:

1. **Claude Code**, via Anthropic's own signed dnf repo
   (`etc/yum.repos.d/claude-code.repo`, package `claude-code`). This is a
   root-owned `/usr/bin/claude` that never self-updates (`claude doctor`
   reports "Auto-updates: Managed by package manager") — it only moves when
   `vekrona-update` runs `dnf upgrade`.
2. **Codex, OpenCode, Pi, and Cursor**, via one system-wide, root-owned
   [mise](https://mise.jdx.dev/) install (`etc/yum.repos.d/mise.repo`,
   package `mise`, plus `nodejs22-npm` for mise's npm backend). `/etc/mise/config.toml`
   pins the tool list and sets a supply-chain cooldown,
   `minimum_release_age = "1d"`: mise will not install or upgrade to a
   release less than a day old, so a same-day compromised release of any of
   these tools is never pulled automatically. The cooldown is verified to
   apply to the npm backend (Codex, Pi) and the aqua backend (OpenCode). It
   does **not** apply to Cursor: `cursor-agent` comes from mise's http
   backend, which only ever exposes the current build, so there is no older
   build for the cooldown to fall back to. Separately, OpenCode's aqua entry
   and Cursor's http entry carry no upstream checksum in `mise`'s registry,
   so integrity for those two rests on HTTPS transport alone, not a pinned
   hash. Both are residual, accepted risks; see `TODO.md`.

Both repo files are GPG-signed (`gpgcheck=1`), and stage `55-agents` does not
trust dnf's own on-demand key import: before installing anything, it
downloads each repo's key, computes its fingerprint locally
(`gpg --import-options show-only`), and `die`s if that fingerprint does not
exactly match the one verified against the vendor out of band
(`ensure_gpg_key_imported`, `lib/common.sh`; fingerprints and URLs are the
`CLAUDE_CODE_GPG_*`/`MISE_GPG_*` constants there). Only once the fingerprint
matches does it `rpm --import` the key and install the package.

`mise install --system`/`mise upgrade --system` only work for
binary-download backends, which rules out Codex and Pi (npm backend); the
one form that installs, upgrades, and reshims all four tools uniformly is to
skip `--system` and instead point plain `mise` at root-owned directories:
`MISE_DATA_DIR=/usr/local/share/mise MISE_CONFIG_DIR=/etc/mise`. This is the
`mise_system` helper in `lib/common.sh`, the one chokepoint stage
`55-agents` and `bin/vekrona-update` both call, so there is exactly one place
that knows how mise is invoked system-wide. `mise_system` runs this through
`sudo`, which resets `HOME` to `/root`; left alone, that would leak npm's and
mise's own caches into `/root` on every install or upgrade. `mise_system`
pins `HOME`, `MISE_CACHE_DIR`, `MISE_STATE_DIR`, and `npm_config_cache` to
paths under `/usr/local/share/mise` instead, so nothing lands outside the
managed tree; verified empirically by diffing a full listing of `/root`
before and after a real (network-downloading) `mise_system install` — zero
new entries. The result, `/usr/local/share/mise/installs/*` and
`/usr/local/share/mise/shims/{codex,pi,opencode,cursor-agent}`, is
root:root and not writable by the user; stage `55-agents` asserts this by
actually attempting a write and expecting it to fail, not by only reading
permission bits.

PATH carries the shims directory,
`/usr/local/share/mise/shims`, in two places, since the sway session and a
login shell/SSH/TTY session build their `PATH` differently: the sway session
picks it up from `config/environment.d/vekrona.conf` (appended to the
existing `PATH`), and a login shell, SSH session, or plain text console
picks it up from `etc/profile.d/vekrona-mise.sh` (a root file, `ensure_root_file`).
`OPENCODE_DISABLE_AUTOUPDATE=true` is set in both of those same two places:
OpenCode has a self-update path of its own, and setting this disables it so
the root-owned mise install is the only thing that ever changes OpenCode's
binary. Codex accepts an equivalent flag
(`-c check_for_update_on_startup=false`) but the launcher that calls it (a
separate stream of work) is expected to pass it. Cursor has no such flag;
its root-owned install already denies its own updater write access, so there
is nothing to disable.

Stage `55-agents` warns, but does not fail, if a user-local copy of any of
these binaries exists under `~/.local/bin` (for example, a native
Claude-Code installer that already put `claude` there on a previously
hand-set-up machine): `~/.local/bin` comes first on `PATH`, so a leftover
copy there silently shadows the managed, root-owned binary and stops it from
ever being the one that runs, or the one `vekrona-update` keeps current.
Remove the flagged file so the name resolves to the managed install instead.

## Agent button

Omarchy-style "agent button": one keystroke or bar click opens a configured
coding agent harness (Claude Code, Codex, opencode, pi, or Cursor Agent) in a
new Ghostty window, or opens the agent on a specific recorded error.

```
Hyper+a         open the coding agent (vekrona-agent --pick)
Hyper+Shift+a   pick a recorded error and open the agent on it (vekrona-error pick)
```

The DankBar plugin `config/DankMaterialShell/plugins/vekronaAgent/` shows the
same two actions as a bar button: left click runs `vekrona-agent --pick`,
right click runs `vekrona-error pick`. A small badge on the icon shows the
unread recorded-error count
(`${XDG_STATE_HOME:-~/.local/state}/vekrona/errors/unread`, watched
event-driven via Quickshell's `FileView`) and hides when it is zero. Stage
`50-user` symlinks the plugin directory in with the rest of
`config/DankMaterialShell/plugins/`, enables it in `plugin_settings.json`,
and inserts `vekronaAgent` into a bar's widget list (before
`notificationButton`) if it is not already present, the same idempotent
pattern used for `vekronaSwayWorkspaces`; `settings.seed.json` already ships
it in place for a fresh install.

`bin/vekrona-agent` resolves harnesses by name on `PATH` (`claude`, `codex`,
`opencode`, `pi`, `cursor-agent`; `claude` is an RPM in `/usr/bin`, the rest
are `mise` shims); a harness that is not installed fails with a clear error
telling you to run `./install.sh 55-agents` or `vekrona-update`. Every
harness launches with its own **default** permission prompts: there is no
yolo/auto-approve flag anywhere in this path. Before launch, `vekrona-agent`
strips every API-key-shaped environment variable (`ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`, `OPENAI_API_KEY`,
`OPENAI_BASE_URL`, `CODEX_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`,
`CURSOR_API_KEY`, `OPENROUTER_API_KEY`) so every harness authenticates
through its own subscription login, never a stray API key left in the
session environment:

| Harness | Subscription |
|---|---|
| Claude Code (`claude`) | Claude Pro/Max, via Claude Code's own OAuth login |
| Codex (`codex`) | ChatGPT |
| opencode, pi | ChatGPT or GitHub Copilot, **not** a Claude subscription (Anthropic's terms only let a Claude subscription's OAuth token authenticate Claude Code itself, enforced since 2026-01-09) |
| Cursor Agent (`cursor-agent`) | Cursor subscription |

Run each harness once by hand first and log in; `vekrona-agent` never
automates that.

The default harness is a single id in
`${XDG_CONFIG_HOME:-~/.config}/vekrona/agent`:

```
vekrona-agent set claude         # set the default harness
vekrona-agent get                # print the default harness
vekrona-agent list                # every known harness: installed? default?
vekrona-agent choose              # always show the picker, set the default, then launch
vekrona-agent                     # launch the default harness (dies with no default set)
vekrona-agent --pick              # launch the default; with no default, show the picker, set it, then launch
vekrona-agent --prompt "fix the build"
vekrona-agent --pick --error 42    # launch with the recorded error's prompt (vekrona-error prompt 42), opening the picker if no default harness is set
vekrona-agent --dry-run ...        # print the final argv instead of launching, one element per line
```

`vekrona-agent` launches `ghostty --class=vekrona.agent
--working-directory=<this repo>` (so a session opens in the vekrona checkout,
not wherever the keybinding happened to fire from) `-e env -u <stripped
vars...> <harness argv>`, detached from the caller (`setsid -f`) so the
keybinding, bar click, or notification action never blocks; a failed launch
still surfaces as a desktop notification (`notify-send -u critical -a
vekrona`), the same as every other error from this tool.

## Update policy

`vekrona-update` is the one command for "update the whole computer": it
takes a pre-update snapper snapshot, runs `dnf upgrade --refresh`, `flatpak
update`, and `mise` (system-wide) upgrade + reshim, then takes a matching
post-update snapshot, printing what changed at each step (each tool's own
output) and the pre-snapshot number with a `vekrona-rollback <N>` hint at the
end. Run it yourself in a terminal:

```
vekrona-update
```

It asks for `sudo` once up front (like `install.sh`), then never prompts
again: `dnf upgrade -y`, `flatpak update --system -y --noninteractive`, and
`mise upgrade` are all non-interactive by default, so nothing about a
routine update requires a `--yes` flag. `flatpak update` runs `--system`
because stage `30-packages` only adds the flathub remote system-wide
(`ensure_flatpak_remote_system`), not per-user, and as root it does not need
`--noninteractive`'s usual job of suppressing a polkit prompt, since root
already has the privilege the system helper would otherwise ask for. A
`mise upgrade --dry-run` runs first and prints a `WARN` line for every
release the `minimum_release_age` cooldown is currently holding back, so a
run that changes less than expected explains why in its own output rather
than silently doing less.

The post-update snapshot is taken from an `EXIT` trap, so even a failing
step (a `die` from a failed `dnf upgrade`, for instance) still leaves a
matched pre/post pair on disk instead of a dangling pre snapshot with
nothing to compare it to; the printed rollback hint is the way back to
before the run regardless of where it failed. If the post-update snapshot
itself cannot be created, the trap surfaces that with a `warn` rather than
swallowing it, but still exits with whatever status the run already had
(a snapshot failure never masks an earlier, more important failure, and
never turns a successful run into a reported failure either). Stage
`20-snapper`'s own dnf actions plugin
(`etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions`)
also fires its own pre/post pair around the `dnf upgrade` transaction inside
this run, nested inside `vekrona-update`'s own pair; that nesting is
expected and harmless (snapper snapshots are cheap CoW, and `NUMBER_LIMIT=10`
prunes old ones), not a bug to work around.

Stay one Fedora release behind: this machine runs F44 until F46 reaches GA.
Staying a release behind gives the NVIDIA driver, Sway/wlroots, and DMS/Qt
time to catch up before this machine takes the upgrade.

The versionlocked set, applied by the stage that installs each package and
recorded in `/etc/dnf/versionlock.toml`:

- Stage `30-packages` locks `sway`, the wlroots package providing the libwlroots soname the installed `sway` links against, `dms`, `quickshell`, `qt6-qtbase`, `qt6-qtdeclarative`, `qt6-qtwayland`, `xremap-wlroots`, the whole compositor and shell stack, so a routine `dnf upgrade` cannot pull one of them out from under versions that were actually tested together.
- Stage `10-nvidia` locks `akmod-nvidia` and every installed `xorg-x11-drv-nvidia*` package, so a routine upgrade cannot install a newer proprietary driver against an untested kernel.

`vekrona-update`'s `dnf upgrade` respects both locks automatically (dnf never
moves a versionlocked package on a plain upgrade); `stages/70-verify.sh`
warns when a lock's `.fcNN` suffix no longer matches the running Fedora
version, which is the signal that a lock is now holding back more than
intended.

To change the `minimum_release_age` cooldown, edit the one line in
`etc/mise/config.toml` and re-run `./install.sh 55`, which reinstalls the
file and re-runs `mise_system install`/`reshim` against the new setting; the
same file also controls which tool versions mise tracks (`[tools]`).

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
make -C vm test       # connects only with the harness key (-i vm/.ssh/id_ed25519, IdentitiesOnly=yes, -F /dev/null and IdentityAgent=none so your ~/.ssh/config and any SSH agent, including 1Password, are never touched); waits for an IPv4 lease (vm/wait-for-ip.sh, event-driven: it watches the libvirt dnsmasq lease file with inotifywait rather than polling on a sleep), waits for SSH, enables linger for the VM user, rsyncs the repo in (excluding .git and vm/.ssh, so the harness key never leaves the host), runs ./install.sh --skip 10-nvidia (which installs everything the harness scripts below need: python3/inotify-tools are not in the kickstart, stage 30-packages installs them before session-check.sh ever runs; git is not installed by any stage or needed in the VM, since the repo arrives by rsync, not by clone), vm/session-check.sh (brings up one headless Sway session and leaves it running for the checks below, see "VM session lifecycle"), vm/agents-check.sh, vm/errors-check.sh, vm/agent-launch-check.sh, vm/session-teardown.sh (tears that session down cleanly), a vekrona-snapshot/vekrona-rollback round trip, reboots the VM and waits for it to actually reboot and for qemu-guest-agent to reconnect, both through libvirt domain events (vm/wait-for-reboot.py), then waits for SSH again, runs vm/rollback-check.sh against that snapshot number, requires `systemctl is-system-running --wait` to report `running` (a degraded boot, with any failed unit, fails the test and prints the failed units), and finally runs vm/login-manager-check.sh to prove the fresh-install login manager (stage 65-login-manager): greetd active, greetd enabled, default target graphical.target. One timed wall-clock wait remains, unlike every other wait here: SSH reachability itself, retried up to `SSH_CONNECT_ATTEMPTS` times, isolated in one `wait_for_ssh` helper in vm/Makefile (see TODO.md)
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

`vm/rollback-check.sh` then confirms the
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

### VM session lifecycle

`vm/session-check.sh`, `vm/agents-check.sh`, `vm/errors-check.sh`, and
`vm/agent-launch-check.sh` each run as their own `ssh` connection (a separate
process with no shared shell state), but the last three need one live
headless Sway session, not one each, and the VM itself can be shared with a
human or another check already logged in and watching it (over
`virt-viewer`/SPICE), so a check must never start a second compositor or
stop a session it did not start. `vm/session-lib.sh` is the one place that
reconciles this: `session_attach_existing` finds whatever session is
already live from a fresh connection (`session_resolve_swaysock`, a
runtime-dir glob for the Sway IPC socket rather than an inherited
`$SWAYSOCK`, since that would not survive a new `ssh` connection anyway, plus
a liveness and `sway-session.target` check), `session_ensure_up` attaches to
one if it finds it live and otherwise starts a fresh headless one (marking
it, in a `$XDG_RUNTIME_DIR` file, as owned by this test run), and
`session_teardown` only stops `sway-session.target` and the Sway unit when
that marker says this test run started them — a session it merely attached
to is left running. `vm/session-check.sh` calls `session_ensure_up`
(`WLR_BACKENDS=headless` Sway under `systemd-run --user` when nothing is
live yet; wait for the IPC socket, confirm `sway-session.target` is active,
start `dms.service`, call `dms ipc call lock status`, validate the xremap
config with `xremap-wlroots --validate-config`) and leaves the session
running either way; `vm/errors-check.sh` and `vm/agent-launch-check.sh` call
`session_attach_existing` to use that same session instead of starting
their own; and `vm/session-teardown.sh`, run once after all three (wired
into `vm/Makefile`), applies the ownership rule above, so nothing
(`dms.service`, `vekrona-errors.service`, …) is ever left running against a
dead compositor, and nothing this test run did not start is ever torn down
out from under someone else.

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
