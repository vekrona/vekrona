# Development

Repo layout, tests, the VM smoke test, the ISO build and CI.

## Layout of the repo

| Path | Contents |
|---|---|
| `install.sh` | stage runner: parses flags and stage names, refreshes sudo, runs `stages/NN-*.sh` in order |
| `lib/common.sh` | shared bash helpers (`log`, `die`, `ensure_*`, `assert_*`), sourced by every stage and by `bin/vekrona-rollback` and `bin/vekrona-snapshot` |
| `lib/display-scale.sh` | derives the internal panel's Sway scale (1 or 2) from its resolution and EDID physical size; `ensure_internal_panel_scale` writes `~/.config/sway/config.d/vekrona-panel-scale.conf` |
| `lib/authselect-vekrona.sh`, `lib/luks-fido2.sh` | helpers for stage `45-auth` (authselect profile with `pam_u2f`, fingerprint, FIDO2 LUKS keyslot, crypttab and initramfs); `70-verify` sources them too |
| `lib/firewall.sh` | firewalld helpers shared by stage `40-system` and `70-verify`: `ensure_default_zone` (public, with the services vekrona uses), the AirPlay UDP range and `ensure_airplay_ports`, the zone port checks |
| `lib/tailnet-ssh.sh` | sshd keys-only drop-in and the firewalld `tailnet` zone (every other zone closes ssh, by dropping the service or with a reject rule) for stage `40-system`; `70-verify` sources it too |
| `lib/facetimehd.sh` | pinned, sha256-verified patjak/facetimehd source build and firmware extraction for stage `15-mac` |
| `stages/*.sh` | one script per stage, numbered so the run order is visible in a directory listing; `install.sh` filters the list per machine with `stage_applies` (`./install.sh --list` prints the result) |
| `config/` | source of truth for dotfiles; stage `50-user` symlinks these into `$HOME`. Stage `50-user` also deletes `~/.config/environment.d/vekrona-gpu.conf`, left by earlier installs (the GPU is now chosen at login by `bin/vekrona-gpu-env`) |
| `etc/` | system files installed into `/etc` by `ensure_root_file` |
| `/usr/local/lib/vekrona/lib` | root-owned copy of `lib/`, mirrored by `ensure_root_tree` in stage `40-system` and compared with the checkout by stage `70-verify`. Systemd system units source their scripts from here, because the home directory is mode 700 and `user_home_t`; every such unit sets `Environment=HOME=/root`, which `lib/common.sh` requires. Tested by `tests/stages/test-root-tree.sh` |
| `bin/vekrona-*` | the CLI tools; stage `50-user` symlinks the whole directory into `~/.local/bin` |
| `config/systemd-user/vekrona-errors.service`, `vekrona-errors-failed.service` | `vekrona-errors.service` runs `vekrona-error watch` (the error pipeline, see [Error pipeline](errors.md)); `vekrona-errors-failed.service` is its `OnFailure=` notifier. Stage `50-user` links and enables them the same way it does `xremap.service` |
| `config/agents/skills/vekrona-diagnose/` | the Claude Code skill an agent uses to investigate a vekrona error; stage `50-user` symlinks it into `~/.claude/skills/`, `~/.codex/skills/`, and `~/.agents/skills/` |
| `fonts/` | vendored AtkynsonMono Nerd Font, Atkinson Hyperlegible Mono, JetBrainsMono Nerd Font and Material Symbols Rounded (OFL, one folder each with its licence; versions in `fonts/SOURCES`), symlinked into `~/.local/share/fonts/vekrona` |
| `config/fontconfig/conf.d/50-vekrona-fonts.conf` | fontconfig aliases: `sans-serif`/`system-ui` prefer Atkinson Hyperlegible Next then Inter (Atkinson has no Cyrillic, Inter covers it), `monospace` prefers AtkynsonMono Nerd Font, Atkinson Hyperlegible Mono, then JetBrainsMono Nerd Font; symlinked into `~/.config/fontconfig/conf.d/` |
| `config/vekrona-shell/` | the vekrona-shell Quickshell config, run as `qs -c vekrona-shell` by `vekrona-shell.service`: bar (Desktops, window title, Caffeine, Tray, Weather, Perf, Sound, Network, Battery, Agent, Notifications, Calendar (next event and clock)), notification daemon and centre, polkit agent, the launcher (`launcher/`: one host with a row of mode tabs, and a module per source: applications, calculator, settings, power commands, web search, agent, clipboard history) and the OSD; `Vekrona/` inside it links to `config/quickshell-shared/Vekrona/`, the design components shared with the lock screen. Stage `50-user` symlinks it into `~/.config/quickshell/` |
| `config/systemd-user/vekrona-lock.service` | the locker, `qs -c vekrona-lock`, started on demand by `bin/vekrona-lock` (`systemctl --user start`, never enabled). `Type=notify`: `config/vekrona-lock/shell.qml` runs `systemd-notify --ready` once Quickshell's `WlSessionLock.secure` says the compositor confirmed the lock, so `vekrona-lock` (and swayidle's `before-sleep`) return only when the screen is locked; `TimeoutStartSec=8s` stays under logind's 15 s inhibit delay and fails visibly. `Restart=on-failure` with no rate limit relocks after a crash |
| `config/systemd-user/vekrona-idle.service` | swayidle: `vekrona-lock start` after 300 s idle, monitors off after 600 s, logind's IdleHint set after 300 s (`vekrona-idlehint yes`, cleared by `vekrona-idlehint no` on input), `vekrona-lock --before-sleep` before sleep (a safety net, see the suspend rows below) and `vekrona-lock start` on logind's lock event. `StartLimitIntervalSec=0` with a restart delay that grows from 1 s to 60 s (`RestartSec=1`, `RestartSteps=6`, `RestartMaxDelaySec=60`): the auto-lock is never given up on, and every failed exit still reaches the error pipeline as a "unit failed" record. The shell, the app switcher and the clipboard history restart the same way. It never suspends itself: logind is the single sleep authority and suspends 25 min after the idle hint (`etc/systemd/logind.conf.d/vekrona-idle.conf`, `IdleAction=suspend`, `IdleActionSec=25min`), i.e. at 30 min, unless a `sleep` inhibitor such as caffeine is held. `etc/systemd/sleep.conf.d/vekrona.conf` sets `MemorySleepMode=deep s2idle` (deep suspend where the hardware offers it, else s2idle); stage 40 restarts logind when either logind drop-in changes (sessions stay up; a reload would not arm the idle timer) |
| `bin/vekrona-suspend now\|--lid` | the one way vekrona suspends: `vekrona-lock start`, then `systemctl suspend`. The launcher's Power view, Sway's lid switch and Sway's sleep key run it; `--lid` does nothing while an external display is connected (logind's "docked" rule). logind cannot cancel a suspend that has begun, and swayidle's before-sleep inhibitor is only a delay lock that ends when the command exits or after `InhibitDelayMaxSec`, so the lock has to come before the request |
| `config/systemd-user/vekrona-lock-guard.service` | a block lock on sleep (`systemd-inhibit --what=sleep --mode=block`). `bin/vekrona-lock` starts it before every lock attempt, and the screen being locked stops it (`bin/vekrona-lock` on success, `ExecStartPost=` of `vekrona-lock.service` at READY, which also covers a locker systemd restarted by itself). A lock that fails leaves it held, so logind refuses idle, lid and `systemctl suspend` and the machine stays awake until a lock succeeds; the failure is a `die` record in the error list. It waits on nothing and wakes nothing |
| `config/systemd-user/vekrona-lid.service` | holds logind's `handle-lid-switch` and `handle-suspend-key` locks while the Sway session runs, so the lid and the sleep key are Sway's: `bindswitch --locked lid:on exec vekrona-suspend --lid` and `bindsym --locked XF86Sleep exec vekrona-suspend now` in `config/sway/config`. `etc/polkit-1/rules.d/50-vekrona-lid.rules` lets a wheel user's user manager hold these two inhibitors, which polkit refuses a process outside every login session. At the greeter, without a session, logind handles them itself |
| `bin/vekrona-agent` | opens a configured coding agent harness from `PATH` (Claude Code, Codex, opencode, pi, or Cursor Agent) in a terminal, with default permission prompts and API-key env vars stripped; see [Agent button](agents.md#agent-button) |
| `bin/vekrona-with-session COMMAND...` | runs COMMAND with `XDG_SESSION_ID` set to the user's graphical session on seat0 (the sway session), and dies when there is none or more than one; used by `vekrona-idlehint`; tested by `tests/stages/test-with-session.sh` |
| `bin/vekrona-idlehint yes\|no` | sets logind's idle hint on the user's graphical session (found through `vekrona-with-session`), called by `vekrona-idle.service`'s swayidle: swayidle 1.9 asks logind for its own process's session, which for a service of the user manager is the Display session and after a text or ssh login not the sway session; tested by `tests/stages/test-idlehint.sh` |
| `bin/*` (the bare-call rule) | a tool that has a side effect needs an explicit verb (`toggle`, `start`, `now`, `run`, ...): a bare call prints `usage: ...` on stderr, exits 2 and touches nothing, so a quoting slip or a loop over `bin/*` cannot toggle keep-awake, lock or suspend the machine. `vekrona-gpu-env` and `vekrona-xkb-env` only print and are exempt. Enforced for every file in `bin/` by `tests/stages/test-bare-call.sh`, which runs each bare against tripwires for the commands that change the machine and a scratch home |
| `bin/vekrona-xkb-env` | prints `XKB_DEFAULT_*` for Sway from `/etc/X11/xorg.conf.d/00-keyboard.conf` (`VEKRONA_XKB_CONF` overrides the path in tests); sourced by `config/sway/environment`, and read by `vekrona-keybindings` for its layout row; tested by `tests/stages/test-xkb-env.sh` |
| `bin/vekrona-gpu-env` | prints `export WLR_DRM_DEVICES=/dev/dri/cardN` only when the NVIDIA driver is loaded and every connected output is on the NVIDIA card, nothing otherwise (`VEKRONA_SYSFS_ROOT` prefixes `/sys` and `/proc` in tests); sourced by `config/sway/environment` at every login, never fails it; tested by `tests/stages/test-gpu-env.sh`; see [PLAN.md](PLAN.md) decision #6 |
| `bin/vekrona-render-theme all\|shell\|gtk\|qt\|firefox\|sway\|rofi` | renders `config/tokens.json`, the theme mode and `config/design.json` to the generated `active-theme.json` (shell) and the GTK, Qt, Firefox, Sway, and rofi configs; a target is required, and `all` is shell, gtk, qt, firefox, sway; rofi prints to stdout and writes nothing; writes managed files with a marker first line, refuses to overwrite unmanaged files; run by `vekrona-theme` and stage `50-user` |
| `vm/` | checks that run inside a vekrona guest (session, agents, error pipeline, agent launch, rollback, login manager), driven by `vekrona-dev checks` and `iso/qemu-test.sh` |
| `iso/` | installable-ISO tooling: `fetch-netinst.sh` (verified Fedora netinstall download), `build.sh` (mkksiso release/test ISO builder), `qemu-test.sh` (install-and-boot test of a test ISO), `lib-vm.sh` + `dev-vm.sh` (the QEMU VM lifetime library and its REPL CLI), `dev-installer.sh` (installer window with a freshly packed `updates.img`), `firstboot/`, `kickstart/` |
| `iso/anaconda/` | the two Anaconda add-ons (`updates/`: `vekrona_account`, `vekrona_signin`, `90-vekrona.conf`), `pack-updates.sh` (builds `updates.img`), `bundle.list` (pinned RPMs layered into it) and `tests/` (add-on unit tests) |
| `tests/` | `run.sh` (single entry point for every headless suite), `errors/` (error pipeline), `stages/` (hardware predicates, stage list, panel scale); every shell test sources `tests/lib.sh`, which disables the real error reporter; `vm/` (serial-console helpers); `fixtures/` (sysfs trees of MacBooks, a desktop and a laptop, used through `VEKRONA_SYSFS_ROOT`) |
| `.github/workflows/iso.yml` | CI: runs `tests/run.sh`, builds the release and test ISOs in a Fedora 44 container, boots the test ISO under QEMU/KVM on the runner, and attaches the release ISO to tagged GitHub releases |
| `docs/PLAN.md` | the design record: decisions, verified machine facts, rollout, verification, known issues |
| `TODO.md` | open follow-ups not yet folded into a stage |

## Tests

`bash tests/run.sh` is the single entry point: it runs all headless
suites, keeps going after a failing one and exits non-zero if any failed.
They need no desktop session or root, but several need Fedora packages
(`anaconda-core`, `authselect`) that do not belong on a desktop, so run them
in the vekrona-dev VM (`vekrona-dev test`, see below) rather than on the
host. There are six suites. CI runs the same command in a
Fedora container (job `unit-tests` in `.github/workflows/iso.yml`), and the
ISO build waits for it.

- `tests/errors/` (Python `unittest`): the error pipeline. Needs
  `python3-gobject` and `dbus-daemon`.
- `tests/stages/` (`bash tests/stages/run.sh`): stage helpers: hardware
  predicates and the per-machine stage list against the sysfs trees in
  `tests/fixtures/` (selected with `VEKRONA_SYSFS_ROOT`), the panel scale, the
  authselect profile rendering, the crypttab FIDO2 option handling and the
  first-boot sudoers drop-in, and the NVIDIA kernel-arg states.
- `iso/anaconda/tests/` (`python3 -B -m unittest discover -s
  iso/anaconda/tests`): the Anaconda add-ons. Needs `python3-dasbus`,
  `python3-fido2` and `anaconda-core`.
- `tests/vm/` (Python `unittest`): the serial-console helpers of
  `iso/lib/qmp.py` that `iso/lib-vm.sh` uses to wait for a prompt and type
  into the console.
- `tests/vm/test-usb-claims.sh`: the USB passthrough pre-flight of
  `iso/lib-vm.sh` (`VEKRONA_DEV_USB` devices whose interface a host process,
  typically `pcscd`, holds through usbfs are refused before the VM starts),
  against a fake sysfs tree selected with `VEKRONA_SYSFS_ROOT`.
- `tests/vm/test-lock.sh`: the start lock of `iso/lib-vm.sh` is released after
  a VM is up, so one script can start its phases back to back.

## Sandbox VM (vekrona-dev)

Changes are verified in [vekrona-dev](https://github.com/vekrona/vekrona-dev),
a Lima VM (Fedora 44 cloud image under QEMU/KVM) that mounts this checkout
read-only, installs it with the real `install.sh`, logs into Sway by typing
at the greeter, drives it with QMP key presses, and checks the screen with
OCR and image metrics computed inside the guest. Nothing under test, and no
test dependency, touches the host desktop.

```
vekrona-dev up                  # once
vekrona-dev install             # after every edit (install.sh reloads a running sway)
vekrona-dev session             # logged-in sway session
vekrona-dev e2e tests/e2e/*.sh  # end-to-end scenarios
vekrona-dev test                # tests/run.sh, inside the VM
```

`tests/e2e/` holds the end-to-end scenarios: host-side scripts that drive
the VM through `vekrona-dev` and read like specifications of what the user
sees. A scenario must fail against the commit before its fix
(`vekrona-dev install --rev <commit>`) and pass after it.

## Guest checks

`vm/` holds checks that run inside a vekrona guest: `session-check.sh`,
`update-check.sh`, `errors-check.sh`, `agent-launch-check.sh`,
`session-teardown.sh`, `rollback-check.sh` and `login-manager-check.sh`.
`vekrona-dev checks` runs the first five in that order, then a
`vekrona-snapshot`/`vekrona-rollback` round trip with a reboot,
`vm/rollback-check.sh` against that snapshot, requires `systemctl
is-system-running --wait` to report `running`, and finishes with
`vm/login-manager-check.sh`. `iso/qemu-test.sh` runs the session,
login-manager and rollback checks against a freshly installed test ISO.

`vm/rollback-check.sh` confirms the rollback left both `root` and a
`root.old-*` subvolume at the top level, `/` mounted from `[/root]`, and the
`/.vekrona-rolled-back-from-<N>` marker in place, and that the backup
subvolume named in the marker exists. `vm/login-manager-check.sh` confirms
`systemctl is-active greetd`, `systemctl is-enabled greetd`, and
`systemctl get-default` is `graphical.target`, proving the fresh-install
login manager stage leaves the machine booting straight into the greeter.

What a VM cannot test, because it has none of the hardware involved: the
NVIDIA stage and every GPU feature that depends on it (stage `10-nvidia` is
always skipped) and the real monitor's modes.

Bluetooth is testable with a virtual controller: the kernel module `hci_vhci`
(package `kernel-modules`) provides `/dev/vhci`, and BlueZ's emulator `btvirt`
(shipped in `bluez-libs-devel`) opens it and answers the HCI commands, so
`hci0` appears in BlueZ and rfkill like a real adapter. `tests/e2e/bluetooth-rfkill.sh`
installs both in the guest, starts `btvirt -l1`, restarts `bluetooth.service`
(it only starts while `/sys/class/bluetooth` exists) and removes the
controller on exit. It cannot test pairing or audio, since no peer device exists.

### VM session lifecycle

`vm/session-check.sh`, `vm/update-check.sh`, `vm/errors-check.sh`, and
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
start `vekrona-shell.service`, call `qs -c vekrona-shell ipc show`, validate the xremap
config with `xremap-wlroots --validate-config`) and leaves the session
running either way; `vm/errors-check.sh` and `vm/agent-launch-check.sh` call
`session_attach_existing` to use that same session instead of starting
their own; and `vm/session-teardown.sh`, run once after all three (wired
into `vekrona-dev checks`), applies the ownership rule above, so nothing
(`vekrona-shell.service`, `vekrona-errors.service`, …) is ever left running against a
dead compositor, and nothing this test run did not start is ever torn down
out from under someone else.

## ISO and CI

`iso/` builds an installable Fedora 44 ISO (Sway and vekrona-shell baked in via a
first-boot install) on top of the official Fedora Everything netinstall, and
`.github/workflows/iso.yml` builds and tests it on every push, pull request,
and tag:

- `iso/fetch-netinst.sh <release> <dest-dir>` downloads and GPG/sha256-verifies
  the official Fedora Everything netinstall ISO for `<release>`, printing its
  path; a verified file already in `<dest-dir>` is reused instead of
  re-downloaded.
- `iso/anaconda/updates/` is the vekrona Anaconda add-ons' filesystem layout
  verbatim (`etc/anaconda/conf.d/90-vekrona.conf`,
  `usr/share/anaconda/addons/{vekrona_account,vekrona_signin}/...`,
  `usr/share/anaconda/dbus/{services,confs}/...`): DBus-module-plus-GUI-spoke
  add-ons in the same shape as Fedora's own in-tree `com_redhat_kdump` addon.
  The `VekronaCategory` sorts at 350, right after Anaconda's System category
  (300) and before User settings (400): Installation Destination comes first,
  and VEKRONA SIGN-IN is insensitive until a partitioning is applied. Custom and
  Blivet-GUI partitioning are not hidden (`blivet-gui` is in the Fedora 44
  Everything netinst `install.img`): their layout is classified `MANUAL_PLAIN` or
  `MANUAL_LUKS` and used as it is, never re-applied.
  `iso/anaconda/bundle.list` pins the extra RPMs (`python3-fido2`,
  `python3-cryptography`, `libfprint`) that `pack-updates.sh` layers into the
  image.
  `iso/build.sh` packs that tree into a gzip'd `newc` cpio (`updates.img`,
  built with `cpio --reproducible` and a sorted file list for a
  deterministic archive) and passes it to `mkksiso -u` for **both** the
  release and test ISOs, so there is exactly one addon source of truth for
  every variant. The account add-on's module holds no account data itself; its
  GUI spoke reads and writes the Users, Timezone, Network and Storage DBus
  modules directly, exactly as Anaconda's own hidden spokes would have.
  `pack-updates.sh` needs `cpio rpm2cpio gzip dnf sha256sum git rsync` and
  names the first missing one before it does anything; `pack-updates.sh
  --check` does only that, and `iso/build.sh` runs it up front.
- `iso/build.sh --netinst <iso> --out <iso>` refuses to run against a dirty
  working tree (the ISO embeds a `git clone` of HEAD, so uncommitted changes
  would silently be missing from it) — commit or stash first. It points the
  cloned checkout's `origin` remote at the source repo's own `origin` URL, so
  the installed system can `git pull` for real. First boot copies that clone
  to `~/.local/share/vekrona` and runs `install.sh` from there, so the first
  install matches the ISO; the installed links stay valid as long as that
  directory stays, and rerunning `install.sh` from another checkout moves them.
  Every kickstart `%post` uses `--erroronfail` so a failing step
  aborts the install instead of continuing silently. It then runs `mkksiso`
  (Fedora 44 host, `lorax`
  installed) to produce the release ISO: interactive on boot, with no
  storage, user, root-password, timezone, language or keyboard kickstart
  commands at all (it boots with `inst.geoloc-use-with-ks` so Anaconda still
  geolocates the language, keyboard and time zone defaults), so Installation
  Destination, the vekrona account spoke and the Keyboard spoke all always
  need a visit; with `--test-ssh-pubkey <file>` it instead produces a fully
  unattended test ISO: sets `lang en_US.UTF-8` and `keyboard --vckeymap=us --xlayouts='us'`, wipes the disk, installs btrfs with LUKS2 encryption
  (kickstart `autopart --type=btrfs --encrypted --luks-version=luks2
  --passphrase=vekrona`, so the vekrona spoke's own `completed` check — which
  reads the same Storage/Users/Timezone/Network module state the spoke would
  otherwise have written — is already satisfied and the hub is skipped
  entirely), creates user `vekrona` (password `vekrona`, in `wheel`), enables
  sshd with that key authorized, boots with `console=ttyS0` and the
  installed system's own GRUB with `console=ttyS0 console=tty0` (so the LUKS
  unlock prompt is visible on the logged serial console too), and reboots
  when Anaconda finishes. The vekrona anaconda.conf drop-in also disables
  `can_copy_input_kickstart`, `can_save_output_kickstart` and
  `can_save_installation_logs`, since none of Anaconda's own kickstart or
  log persistence redacts the plaintext LUKS passphrase before writing it to
  the installed system. `mkksiso` rebuilds the ISO's EFI boot image
  (`mkefiboot`), which loop-mounts a small FAT image, so the container this
  runs in needs `/dev/loop-control` plus `--cap-add SYS_ADMIN --cap-add
  MKNOD --device /dev/loop-control --device-cgroup-rule='b 7:* rmw'
  --security-opt label=disable` (a rootful container; rootless podman
  refuses device-cgroup rules outright) — `iso/build.sh` itself `mknod`s
  `/dev/loop0`-`/dev/loop7` if missing so it never depends on the host
  already having free loop devices. `iso/Containerfile` plus `podman build
  -t vekrona-iso-builder -f iso/Containerfile .` and `sudo podman run --rm
  <the flags above> -v "$PWD:/src:Z" -w /src vekrona-iso-builder bash
  iso/build.sh ...` reproduce this locally. Building from a git worktree
  needs one more mount: a worktree's `.git` is a pointer file to the main
  repository's `.git` directory, which must exist at the same path inside the
  container (`-v <main-checkout>/.git:<main-checkout>/.git:ro`); without it
  `iso/build.sh` stops with "not a git repository", names the worktree and
  prints that mount.
- The installed system runs `vekrona-firstboot.service` once on first boot:
  it runs `./install.sh` as the `vekrona` user (skipping `10-nvidia` when
  there is no NVIDIA GPU), then writes `/var/lib/vekrona/firstboot.done` or
  `firstboot.failed` and reboots into `greetd` on success.
- `iso/qemu-test.sh [--print] <test.iso>` boots that test ISO under QEMU/KVM
  (UEFI via OVMF, 4 GiB RAM by default, 4 vCPUs, a 40G qcow2 disk, user-mode
  networking with an SSH port forward). Both phases run through
  `iso/lib-vm.sh`, the library behind `iso/dev-vm.sh`: QEMU lives in a
  transient systemd user unit with a memory cap, a hard runtime limit and
  binding to the test's pid, so the VM disappears even when the test is killed
  with SIGKILL. The library's single-VM guard refuses to start next to other
  VMs; `VEKRONA_VM_COEXIST="name ..."` acknowledges foreign ones that may keep
  running. `--print` shows both QEMU command lines and starts nothing.
  Phase 1 installs from the ISO with `-no-reboot`, so QEMU exits when Anaconda
  reboots, and the test checks that its exit status is 0. Phase 2 boots the
  installed disk (same disk image and UEFI variables), whose serial console is
  a socket. Whenever the serial log shows "Please enter passphrase" the test
  writes `vekrona` into that socket, at most 3 times per boot, and a prompt that
  comes back after the typed passphrase counts as an attempt. That happens
  three times: the first boot, the boot after the firstboot reboot, and the
  boot after the rollback. Waits use events: the serial log (a stream follower
  that also matches a prompt without trailing newline), the QEMU pid, and
  `inotifywait` on the guest for the firstboot marker. The only polling is
  the SSH readiness check, because nothing tells the host when the guest's
  sshd listens (it retries on every serial output plus a 3-second backstop).
  Once SSH is up it first asserts the installed-system account
  invariants: root is on a LUKS2 mapper device (`findmnt`/`lsblk`
  TYPE=`crypt`, `cryptsetup luksDump` Version 2), `vekrona` is in `wheel`,
  root is locked (`passwd -S root` reports `L`), the hostname is `vekrona`,
  the timezone is `UTC`, and none of `/root/anaconda-ks.cfg`,
  `/root/original-ks.cfg` or `/var/log/anaconda` exist on the installed
  system (the plaintext LUKS passphrase would otherwise end up in one of
  them). It authenticates with the matching test private key
  (`VEKRONA_TEST_SSH_KEY`), waits for the firstboot completion marker
  (printing `firstboot.failed` plus `journalctl -u vekrona-firstboot` and
  failing if firstboot failed), then for the post-firstboot reboot and SSH
  again (the guest's `boot_id` must have changed); and finally asserts
  `systemctl is-system-running --wait` is
  `running` (printing failed units otherwise), `greetd` is active, and runs
  `vm/session-check.sh`, `vm/login-manager-check.sh`, `./install.sh --skip
  10-nvidia 70` (verify: warnings allowed, no `FAIL:`), and a
  `vekrona-snapshot`/`vekrona-rollback` round trip, over SSH with the same
  options throughout (test key only, `IdentitiesOnly`, `-F
  /dev/null`, `IdentityAgent=none`, no known-hosts file). Timeouts are
  env-overridable (`VEKRONA_INSTALL_TIMEOUT`, `VEKRONA_SSH_TIMEOUT`,
  `VEKRONA_FIRSTBOOT_TIMEOUT`, `VEKRONA_REBOOT_TIMEOUT`, and
  `VEKRONA_QEMU_RAM_MB`, `VEKRONA_QEMU_VCPUS`, `VEKRONA_QEMU_DISK_GB`,
  `VEKRONA_QEMU_DISPLAY=none|gtk`); on any failure it prints the serial
  console log tail (also kept in `VEKRONA_QEMU_LOG_DIR`) before tearing the VM
  and its disk down through the library. With
  `VEKRONA_QEMU_KEEP_DISK_ON_FAILURE=1` a failed run keeps the disk
  (`iso/dev/qemu-test`) for inspection; boot it with `iso/dev-vm.sh up --name
  qemu-test --profile disk`. A full run takes about 20-25 minutes on the
  maintainer's host.

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

The `iso.yml` workflow has four jobs: `unit-tests` (Fedora 44 container,
`bash tests/run.sh`), `build` (needs `unit-tests`; Fedora 44 container, caches
the downloaded netinstall ISO by release, builds both the release and a
throwaway-keyed test ISO, uploads both as artifacts), `test` (enables KVM on
the `ubuntu-latest` runner and runs `iso/qemu-test.sh` against the test ISO,
uploading the serial logs on any outcome), and `release` (tags only, attaches
the release ISO and its checksum to the GitHub release).

## Decisions log

The full rationale, every verified machine fact, and the complete
rollout and verification checklist behind these docs live in
`docs/PLAN.md`. Read it before changing anything in stage `10-nvidia`, the
versionlocked set, or the cleanup stages (`90a-switch-dm`, `90b-remove`);
those decisions came out of an adversarial review and are easy to undo by
accident.
