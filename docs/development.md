# Development

Repo layout, tests, the VM smoke test, the ISO build and CI.

## Layout of the repo

| Path | Contents |
|---|---|
| `install.sh` | stage runner: parses flags and stage names, refreshes sudo, runs `stages/NN-*.sh` in order |
| `lib/common.sh` | shared bash helpers (`log`, `die`, `ensure_*`, `assert_*`), sourced by every stage and by `bin/vekrona-rollback` and `bin/vekrona-snapshot` |
| `lib/display-scale.sh` | derives the internal panel's Sway scale (1 or 2) from its resolution and EDID physical size; `ensure_internal_panel_scale` writes `~/.config/sway/config.d/vekrona-panel-scale.conf` |
| `lib/authselect-vekrona.sh`, `lib/luks-fido2.sh` | helpers for stage `45-auth` (authselect profile with `pam_u2f`, fingerprint, FIDO2 LUKS keyslot, crypttab and initramfs); `70-verify` sources them too |
| `lib/facetimehd.sh` | pinned, sha256-verified patjak/facetimehd source build and firmware extraction for stage `15-mac` |
| `stages/*.sh` | one script per stage, numbered so the run order is visible in a directory listing; `install.sh` filters the list per machine with `stage_applies` (`./install.sh --list` prints the result) |
| `config/` | source of truth for dotfiles; stage `50-user` symlinks these into `$HOME`. Stage `50-user` also deletes `~/.config/environment.d/vekrona-gpu.conf`, left by earlier installs (the GPU is now chosen at login by `bin/vekrona-gpu-env`) |
| `etc/` | system files installed into `/etc` by `ensure_root_file` |
| `bin/vekrona-*` | the CLI tools; stage `50-user` symlinks the whole directory into `~/.local/bin` |
| `config/systemd-user/vekrona-errors.service`, `vekrona-errors-failed.service` | `vekrona-errors.service` runs `vekrona-error watch` (the error pipeline, see [Error pipeline](errors.md)); `vekrona-errors-failed.service` is its `OnFailure=` notifier. Stage `50-user` links and enables them the same way it does `xremap.service` |
| `config/agents/skills/vekrona-diagnose/` | the Claude Code skill an agent uses to investigate a vekrona error; stage `50-user` symlinks it into `~/.claude/skills/`, `~/.codex/skills/`, and `~/.agents/skills/` |
| `fonts/` | vendored JetBrainsMono Nerd Font (OFL, v3.5.1), symlinked into `~/.local/share/fonts/vekrona` |
| `config/fontconfig/conf.d/50-vekrona-fonts.conf` | fontconfig aliases: `sans-serif`/`system-ui` prefer Atkinson Hyperlegible Next then Inter (Atkinson has no Cyrillic, Inter covers it), `monospace` prefers JetBrainsMono Nerd Font; symlinked into `~/.config/fontconfig/conf.d/` |
| `config/DankMaterialShell/plugins/vekronaSwayWorkspaces/` | DMS DankBar plugin: always shows Sway workspaces 1-5 plus any existing 6-10, replacing the stock workspace switcher (see [The vekronaSwayWorkspaces DankBar plugin](daily-use.md#the-vekronaswayworkspaces-dankbar-plugin)); stage `50-user` symlinks the whole `plugins/` directory into `~/.config/DankMaterialShell/plugins/` |
| `config/DankMaterialShell/plugins/vekronaAgent/` | DMS DankBar plugin: agent-button icon with an unread-error badge, left click opens the default coding agent, right click opens the recorded-error picker (see [Agent button](agents.md#agent-button)) |
| `bin/vekrona-agent` | opens a configured coding agent harness (Claude Code, Codex, opencode, pi, or Cursor Agent) in a terminal, with default permission prompts and API-key env vars stripped; see [Agent button](agents.md#agent-button) |
| `bin/vekrona-xkb-env` | prints `XKB_DEFAULT_*` for Sway from `/etc/X11/xorg.conf.d/00-keyboard.conf` (`VEKRONA_XKB_CONF` overrides the path in tests); sourced by `config/sway/environment`, and read by `vekrona-keybindings` for its layout row; tested by `tests/stages/test-xkb-env.sh` |
| `bin/vekrona-gpu-env` | prints `export WLR_DRM_DEVICES=/dev/dri/cardN` only when the NVIDIA driver is loaded and every connected output is on the NVIDIA card, nothing otherwise (`VEKRONA_SYSFS_ROOT` prefixes `/sys` and `/proc` in tests); sourced by `config/sway/environment` at every login, never fails it; tested by `tests/stages/test-gpu-env.sh`; see [PLAN.md](PLAN.md) decision #6 |
| `bin/vekrona-rofi-theme` | prints a `rofi -theme-str` string from the active vekrona/DMS theme; shared by `vekrona-keybindings` and `vekrona-agent` so the rofi styling lives in one place |
| `vm/` | libvirt smoke-test harness: Makefile, kickstart, session, agents, error-pipeline, agent-launch, rollback, and login-manager checks |
| `iso/` | installable-ISO tooling: `fetch-netinst.sh` (verified Fedora netinstall download), `build.sh` (mkksiso release/test ISO builder), `qemu-test.sh` (install-and-boot test of a test ISO), `lib-vm.sh` + `dev-vm.sh` (the QEMU VM lifetime library and its REPL CLI), `dev-installer.sh` (installer window with a freshly packed `updates.img`), `firstboot/`, `kickstart/` |
| `iso/anaconda/` | the two Anaconda add-ons (`updates/`: `vekrona_account`, `vekrona_signin`, `90-vekrona.conf`), `pack-updates.sh` (builds `updates.img`), `bundle.list` (pinned RPMs layered into it) and `tests/` (add-on unit tests) |
| `tests/` | `run.sh` (single entry point for every headless suite), `errors/` (error pipeline), `stages/` (hardware predicates, stage list, panel scale), `vm/` (serial-console helpers), `fixtures/` (sysfs trees of MacBooks, a desktop and a laptop, used through `VEKRONA_SYSFS_ROOT`) |
| `.github/workflows/iso.yml` | CI: runs `tests/run.sh`, builds the release and test ISOs in a Fedora 44 container, boots the test ISO under QEMU/KVM on the runner, and attaches the release ISO to tagged GitHub releases |
| `docs/PLAN.md` | the design record: decisions, verified machine facts, rollout, verification, known issues |
| `TODO.md` | open follow-ups not yet folded into a stage |

## Tests

`bash tests/run.sh` is the single entry point: it runs all headless
suites, keeps going after a failing one and exits non-zero if any failed.
They need no VM, desktop session or root. There are six suites. CI runs the same command in a
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

## VM smoke test

`VM_NAME` and `VM_USER` (default `vekrona-test` and `vekrona`) are validated
by the Makefile against `[A-Za-z0-9._-]+`, starting with a letter or digit,
before any target runs.

`VM_MEMORY_MB`, `VM_VCPUS` and `VM_DISK_GB` (default `8192`, `4` and `40`) size
the domain `make -C vm create` defines, e.g. `make -C vm create VM_NAME=foo
VM_MEMORY_MB=6144` when the host cannot spare 8 GB for a second VM.

```
make -C vm deps      # installs virt-install/virt-viewer/libvirt-client/inotify-tools/ImageMagick/python3-libvirt if missing, enables the virtqemud/virtnetworkd/virtstoraged sockets, starts and autostarts the libvirt "default" network, adds you to the libvirt group (log out and back in for that to take effect)
make -C vm create     # generates vm/ks-$(VM_NAME).cfg from vm/ks.cfg.in (one generated kickstart per VM name, gitignored, so `make create VM_NAME=foo` next to an existing vekrona-test VM regenerates the right file instead of reusing a stale hostname), generating a dedicated harness SSH key pair at vm/.ssh/id_ed25519 (ed25519, no passphrase, gitignored) if it doesn't exist yet, and substituting your personal SSH public key (first of ~/.ssh/id_ed25519.pub, id_rsa.pub, *.pub, or set VM_SSH_PUBKEY), the harness key, and VM_NAME (as the guest hostname) into the kickstart; virt-install: Fedora Everything netinstall of the release set by FEDORA_RELEASE in vm/Makefile (currently 44), with vm/install-tree.sh resolving the Fedora geo-redirector to one concrete mirror and verifying it serves the install tree before virt-install ever touches it (no retries: a redirector that does not itself redirect is rejected outright), + that kickstart (btrfs autopart, NOPASSWD sudo, password `vekrona` for graphical login, system sleep disabled in the guest because virtio-gpu does not survive suspend and resume (DMS would otherwise suspend an idle VM after 30 min and wedge Sway on its display), `%packages` limited to what the harness itself needs before any stage has run: `@core rsync qemu-guest-agent`; openssh-server is already an @core mandatory package; both the harness key and your personal key are authorized for the VM user); the --os-variant hardware profile is fedora<release> when the host's osinfo database knows it, otherwise the newest known profile plus a warning naming `osinfo-db-import --user --latest`; the VM gets a virtio video device, a local-only SPICE display (`--graphics spice,listen=127.0.0.1`), and a guest-agent channel requested explicitly; the serial console is logged to `/var/log/libvirt/qemu/$(VM_NAME)-serial0.log` (root-owned, read it with sudo) so an install or boot failure can be diagnosed afterwards; the domain is marked as owned by this harness in its libvirt metadata (see `destroy` below); the kickstart shuts the VM down after %post, then this target boots it with `virsh start`
make -C vm test       # connects only with the harness key (-i vm/.ssh/id_ed25519, IdentitiesOnly=yes, -F /dev/null and IdentityAgent=none so your ~/.ssh/config and any SSH agent, including 1Password, are never touched); waits for an IPv4 lease (vm/wait-for-ip.sh, event-driven: it watches the libvirt dnsmasq lease file with inotifywait rather than polling on a sleep), waits for SSH, enables linger for the VM user, rsyncs the repo in with --delete (so a file removed or renamed in the repo disappears from the guest too; .git and vm/.ssh are excluded, which also protects them from deletion, so the harness key never leaves the host), runs ./install.sh --skip 10-nvidia (which installs everything the harness scripts below need: python3/inotify-tools are not in the kickstart, stage 30-packages installs them before session-check.sh ever runs; git is not installed by any stage or needed in the VM, since the repo arrives by rsync, not by clone), vm/session-check.sh (brings up one headless Sway session and leaves it running for the checks below, see "VM session lifecycle"), vm/agents-check.sh, vm/errors-check.sh, vm/agent-launch-check.sh, vm/session-teardown.sh (tears that session down cleanly), a vekrona-snapshot/vekrona-rollback round trip, reboots the VM and waits for it to actually reboot and for qemu-guest-agent to reconnect, both through libvirt domain events (vm/wait-for-reboot.py), then waits for SSH again, runs vm/rollback-check.sh against that snapshot number, requires `systemctl is-system-running --wait` to report `running` (a degraded boot, with any failed unit, fails the test and prints the failed units), and finally runs vm/login-manager-check.sh to prove the fresh-install login manager (stage 65-login-manager): greetd active, greetd enabled, default target graphical.target. One timed wall-clock wait remains, unlike every other wait here: SSH reachability itself, retried up to `SSH_CONNECT_ATTEMPTS` times, isolated in one `wait_for_ssh` helper in vm/Makefile (see TODO.md)
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
place, and that the backup subvolume named in the marker exists. After the reboot that follows, `vm/login-manager-check.sh` confirms
`systemctl is-active greetd`, `systemctl is-enabled greetd`, and
`systemctl get-default` is `graphical.target`, proving the fresh-install
login manager stage actually leaves the VM bootable straight into the
greeter. `make -C vm console` and `make -C vm ssh` give interactive access to
the VM in between, and `make -C vm viewer` gives graphical access.

What the VM cannot smoke-test, because the VM has none of the hardware
involved: the NVIDIA stage and every GPU feature that depends on it (stage
`10-nvidia` is always skipped in `make -C vm test`), the named 4K 119.88 Hz
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
  to `~/.local/share/vekrona` and runs `install.sh --no-pull`, so the first
  install matches the ISO; every later `./install.sh` fast-forwards it from
  GitHub first. Every kickstart `%post` uses `--erroronfail` so a failing step
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
  options as `vm/Makefile` (harness key only, `IdentitiesOnly`, `-F
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
