# Update policy

How the machine is updated, what is version-locked, and how to move to the next Fedora release.

## The update pipeline

Updates are found every morning, offered to you, and installed at midnight unless you say otherwise. Everything that
changes the system runs as root in systemd units, so a long `dnf upgrade` never outlives a `sudo` credential and a
failure never depends on a terminal.

```
09:00 (and 5 min after boot)    vekrona-update-check.timer -> vekrona-update-check.service
        dnf, Proton repo and Flatpak are queried; /var/lib/vekrona/updates.json is rewritten
        something pending and not skipped today -> vekrona-update-night.timer is armed
login or updates.json changes   vekrona-update-notify (user): "updates are ready" [Install now] [Not tonight]
00:00, waking the machine       vekrona-update-night.timer -> vekrona-update-night.service
        nothing pending         suspend, unless somebody is at the keyboard
        somebody at the keyboard  ask [Install and reboot] [Skip tonight]; no answer in 10 minutes means skip
        nobody there            install
install                         vekrona-update-apply --offline: reboot, dnf runs in system-update.target, reboot again
next boot                       vekrona-update-post.service: report the result, rewrite updates.json
```

- **The check** (`libexec/vekrona-update-check`, root, under the lock `/run/vekrona-update.lock`) runs `vekrona-proton
  stage`, `dnf5 check-upgrade --refresh --json`, `dnf5 upgrade --assumeno`, `flatpak remote-ls --updates --system`.
  check-upgrade lists every newer package, including those `dnf5 upgrade` skips for conflicts
  or broken dependencies (RPM Fusion's `mesa-va-drivers-freeworld` lags behind Fedora's mesa); the declined
  `upgrade` names the skipped ones, they are left out of the groups and logged. It writes `/var/lib/vekrona/updates.json` in one rename: `checked`, `pending`, `night_armed` and `groups`. The groups are
  System packages (a dnf-installed `claude-code` shows up here), Flatpak and Proton, and a group with nothing in it is left out. It arms `vekrona-update-night.timer` when something is pending
  and `/var/lib/vekrona/update-skip` does not hold today's date, and disarms it otherwise. The timer fires at 09:00 and
  not at midnight, so the check never races the night run.
  Before the first check, stage 40 runs `libexec/vekrona-update-seed`, which writes the same file with `pending:
  false` and no groups, so the launcher's Power view always has a file (and a directory) to watch.
- **The notification** is the user side (`bin/vekrona-update-notify`, started by a path unit on `updates.json` and at
  login, once per distinct content). [Install now] starts `vekrona-update-now.service`; [Not tonight] starts
  `vekrona-update-skip.service`, which writes today's date to `update-skip`, disarms the night timer and marks
  `night_armed: false`. Ignoring the toast changes nothing: midnight installs. A `wheel` user at the machine's own
  session, or one of its systemd user services (the toast and the launcher run `systemctl start` from those, outside
  any login session), may start exactly the `now`, `reboot`, `poweroff` and `skip` units without a password
  (`etc/polkit-1/rules.d/50-vekrona-update.rules`), and nothing else.
- **Midnight** (`libexec/vekrona-update-night`) has `WakeSystem=true`, so a sleeping machine wakes for it. It checks
  again first. A user at the keyboard is a logind session with `Type=wayland`, `Active=yes`, `LockedHint=no` and
  `IdleHint=no`; that user is asked through `bin/vekrona-update-ask`, for `VEKRONA_UPDATE_ASK_TIMEOUT` seconds (600).
  A timeout, a closed notification or [Skip tonight] skips the night and the machine goes back to sleep through
  logind's `IdleAction`. A locked or idle session, or none, installs without asking. If anything holds a `block`
  inhibitor on shutdown (systemd 257 applies those to root too), the unit fails and names the holder, instead of
  forcing a reboot over it.
- **Update and restart / Update and shut down** in the launcher power menu start `vekrona-update-reboot.service` and
  `vekrona-update-poweroff.service`, which run the same offline install now.
- **The offline install** (`libexec/vekrona-update-apply --offline [--poweroff]`) stages the Proton RPMs, takes the snapper
  pre snapshot, runs `flatpak update` online, stores dnf's transaction with `dnf5 upgrade
  --offline`, writes the marker `/var/lib/vekrona/offline-pending` and runs `dnf5 offline reboot` (with `--poweroff`
  when asked). dnf then applies the transaction in `system-update.target`, where nothing else is running, and reboots
  again. The transaction has not run when the script ends, so the post snapshot is not taken there: the marker's second
  line (`pre=N`) hands the pre snapshot to `vekrona-update-post`, which closes the pair after the transaction. When dnf has
  nothing to install, only Flatpak ran, the pair is closed at once and the machine does not reboot. The midnight run
  (`vekrona-update-night.service`) has `ConditionACPower=true`: on battery it is skipped and the update waits for the next night.
- **The online install** (`vekrona-update-apply --online`) ends the same way: after the dnf transaction it builds what the
  newest kernel is missing and makes it the GRUB default, or fails the run.
- **After the reboot**, `vekrona-update-post.service` runs because the marker exists. It repairs the 1Password repo file
  (the RPM's `%post` disables `repo_gpgcheck`), closes the snapshot pair, makes the newest kernel the GRUB default,
  shows a "System updated" notification and only then runs the check again (it needs the network; a failing check fails the
  unit but no longer stands between the kernel and the GRUB default) so `updates.json` says `pending: false`. On an NVIDIA machine the promotion first builds the new kernel's nvidia module (the offline
  transaction skips akmods), regenerates its initramfs and only then makes that kernel the GRUB default, because
  `UPDATEDEFAULT=no` keeps kernel-install from doing it; when that fails, the previous kernel stays the default and the
  unit fails, keeping the marker so the next boot retries. dnf keeps a transaction that did not finish stored, so a transaction that
  `dnf5 offline status` still reports makes the unit fail, with the status and the tail of `dnf5 offline log` in its
  message. After a night install the greeter is on screen and nobody is logged in; logind's `IdleAction=suspend` (25
  minutes, see [Sleep](development.md)) puts the machine back to sleep.
- **At every boot** on an NVIDIA machine, `akmods.service` runs the drop-in `vekrona-nvidia-initramfs` after its build.
  The drop-in compares file times only: it regenerates the running kernel's initramfs (and then verifies it) when the
  image is missing or older than the nvidia module, `99-nvidia-dracut.conf` or `vekrona-nvidia.conf`, and otherwise
  exits without opening the 360 MB image, because reading it costs seconds of disk and CPU on every battery boot. It
  takes the same kernel lock as `vekrona-kernel-ready` and an update (waiting at most 600 s, then failing the unit).
- **Failures** need no unit of their own. A failed root unit is a "unit failed" record in the system journal, and the
  `die()` message that ended it is a second record of its own (the scripts report to `vekrona-error` as root, whose
  entries the watcher accepts from uid 0); the watcher turns both into entries in the error store (shown by the robot's red
  dot while you are logged in, and at your next login otherwise). The unit's journal, `journalctl -u
  vekrona-update-night.service`, holds the detail. A Proton feed that cannot be read is not such a failure: the check and
  the update go on without new Proton packages, and the problem is one record of its own.

### Updating by hand

`vekrona-update now` is the one command for "update the whole computer, now" (a bare `vekrona-update` is refused):

```
vekrona-update now
```

It starts `vekrona-update-now.service` (no `sudo`) and shows the unit's journal until it ends; it exits 0 when the update
succeeded and 1 when it failed or was stopped. It learns the end from the journal, where systemd logs "Finished",
"Failed with result ..." or "Stopped" for the unit, and not from `systemctl start --wait`: the `dnf upgrade` can upgrade
systemd, whose scriptlets re-execute PID 1 in the middle of the run, and that drops the D-Bus signal `--wait` waits for,
so `systemctl` never returned for a run that had finished. Started while the unit already runs, the command follows that
run to its end. The unit runs `vekrona-update-apply --online`: `vekrona-proton stage`, a pre-update snapper snapshot, `dnf upgrade
--refresh`, the 1Password repo repair, `flatpak update`, the matching post-update snapshot, and a check that rewrites
`updates.json`. Each tool's own output is shown, and the pre-snapshot number comes with a `vekrona-rollback <N>` hint at
the end.

Every step is non-interactive: `dnf upgrade -y` and `flatpak update --system -y --noninteractive` need no
confirmation. `flatpak update` runs
`--system -y --noninteractive` because stage `30-packages` only adds the
flathub remote system-wide (`ensure_flatpak_remote_system`), not per-user; a
plain user-scope update failed on the appstream refresh.

Coding agents are not part of this pipeline: vekrona installs none (see [Coding agents](agents.md)), so a harness
installed per user updates itself, and a dnf-installed `claude-code` moves with `dnf upgrade`.

The post-update snapshot is attempted exactly once. On success it is taken
at the end of the run; if a step fails first, an `EXIT` trap takes it, so a
failing step (a failed `dnf upgrade`, for instance) still leaves a matched
pre/post pair instead of a dangling pre snapshot; the printed rollback hint
is the way back to before the run regardless of where it failed. If the post
snapshot cannot be created at the end of a successful run, that is a fatal
error; if it cannot be created in the trap, the trap surfaces it with a
`warn` and still exits with the status the run already had, so a snapshot
failure never masks an earlier failure. Stage
`20-snapper`'s own dnf actions plugin
(`etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions`)
also fires its own pre/post pair around the dnf transaction (in an offline install, the one that runs in the update boot),
nested inside the script's own pair on the online path; that nesting is
expected and harmless (snapper snapshots are cheap CoW, and `NUMBER_LIMIT=10`
prunes old ones), not a bug to work around.

### Where the root side lives

The units run scripts from `/usr/local/lib/vekrona` (`lib/`, `libexec/`, and `bin/vekrona-proton` and
`bin/vekrona-update-ask` under `bin/`), which stage `40-system` mirrors from the checkout; a unit cannot run from the
0700 home directory. Every unit sets `Environment=HOME=/root`, because `lib/common.sh` needs `$HOME`. Stage `70-verify`
compares the copies, the unit files and the polkit rule with the checkout. The check timer is the only unit enabled
besides `vekrona-update-post.service`; the night timer has no `[Install]` section, and exists only while the check keeps
it armed.

To opt out of the night install, `sudo systemctl mask --now vekrona-update-night.timer`: the check keeps listing updates
and the toast still offers [Install now].

Stay one Fedora release behind: this machine runs F44 until F46 reaches GA.
Staying a release behind gives the NVIDIA driver, Sway/wlroots, and Quickshell/Qt
time to catch up before this machine takes the upgrade.

Updates flow through multiple channels:

- **dnf upgrade** covers all system packages: Fedora, RPM Fusion, COPRs, and vendor repos (1Password, Proton VPN). This is protected by snapper pre/post snapshots created by the actions plugin (`etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions`), so any dnf transaction is automatically rolled back on failure via `vekrona-rollback`.
- **flatpak update** covers Flatpak apps: currently Zed, Signal and OBS Studio.
- **nix profile upgrade --all** covers devbox (installed through `nix profile`). Nothing runs it: devbox is still updated by hand (see [TODO.md](../TODO.md)).

The versionlocked set, applied by the stage that installs each package and
recorded in `/etc/dnf/versionlock.toml`:

- Stage `30-packages` locks `sway`, the wlroots package providing the libwlroots soname the installed `sway` links against, `quickshell`, `qt6-qtbase`, `qt6-qtdeclarative`, `qt6-qtwayland`, `xremap-wlroots`, the whole compositor and shell stack, so a routine `dnf upgrade` cannot pull one of them out from under versions that were actually tested together.
- Stage `10-nvidia` locks `akmod-nvidia` and every installed `xorg-x11-drv-nvidia*` package, so a routine upgrade cannot install a newer proprietary driver against an untested kernel.

`vekrona-update`'s `dnf upgrade` respects both locks automatically (dnf never
moves a versionlocked package on a plain upgrade); `stages/70-verify.sh`
warns when a lock's `.fcNN` suffix no longer matches the running Fedora
version, which is the signal that a lock is now holding back more than
intended.

## rune

rune is the default editor (`$EDITOR`, and `.md` and text files open in Ghostty). It is a Rust terminal Markdown
editor from [aka-rider/rune](https://github.com/aka-rider/rune), installed by stage `30-packages` from the GitHub
release RPM `rune-<ver>-1.<arch>.rpm`. `vekrona-update` does not update it. To bump it by hand:

1. Change `VEKRONA_RUNE_VERSION` and `VEKRONA_RUNE_RELEASE` (the `-<release>` in the RPM file name) in `lib/common.sh`.
2. Take each arch's sha256 from the GitHub API asset `digest` field in `https://api.github.com/repos/aka-rider/rune/releases/tags/v<ver>`.
3. Download each RPM and confirm it with `sha256sum`.
4. Pin the values in `VEKRONA_RUNE_SHA256` in `lib/common.sh`.
5. Run `./install.sh 30`.

Trust model: TLS to github.com plus the API digest, reviewed into the repo at bump time. Unlike Proton, the sum is
not fetched at install time. rune's RPMs are unsigned, so the pinned sha256 on a root-owned copy is the only check
before dnf installs it.

## Proton apps

Proton Mail (which includes Calendar), Proton Pass and Proton Authenticator are native apps installed from Proton's
own RPMs. Proton publishes them only as files linked from JSON feeds (`proton.me/download/.../version.json`), has no dnf
repo for them, and its apps do not update themselves on Linux. So `bin/vekrona-proton` builds the repo:

- `vekrona-proton stage` (root) reads each feed (`lib/proton.sh`, `VEKRONA_PROTON_FEEDS`), picks the newest `Stable`
  release whose rollout is 100% (a half-rolled-out release is skipped until Proton finishes it), downloads its `.rpm`
  and checks the SHA512 from the feed. It keeps one RPM per package in `/var/lib/vekrona/proton-repo/` and runs
  `createrepo_c --update`. It downloads only when the feed is newer than the installed package and the RPM is not
  already staged, so running it again is harmless.
- `etc/yum.repos.d/vekrona-proton.repo` points dnf at that directory (`includepkgs` limits it to the three packages), so
  plain `dnf install` and `dnf upgrade` handle the apps like any others, snapper snapshots included.
- `vekrona-proton check` (any user, read-only) prints the installed and the latest feed version of each package.
- Stage `30-packages` stages, installs the repo file, then installs the packages. The update check and every update run
  `vekrona-proton stage` first, so new releases arrive with the rest of the updates.

Trust model: Proton signs none of these RPMs (no GPG signature, no `repo_gpgcheck`), so the repo has `gpgcheck=0`.
What protects a download is TLS to `proton.me` plus the SHA512 from the feed on the same origin, and every RPM URL
in a feed must start with `https://proton.me/download/` and continue with plain path characters (no `..`, `%`, `?` or
glob characters); a feed version must look like a version, because it becomes part of a file name. That catches a corrupted or truncated download and a feed
entry that points elsewhere, but not a compromise of proton.me itself: whoever controls the feed controls the
checksum too. The repo directory is root-owned and only `vekrona-proton stage` writes to it. The downloaded RPM's
name and version must match the feed's before it enters the repo.

Release upgrade procedure:

1. Pin the new release's RPM Fusion keys first. They are keyed by Fedora release (`rpmfusion-{free,nonfree}-fedora-<N>` in `VEKRONA_REPO_KEY_FINGERPRINTS`, see [Coding agents](agents.md)), and stage `00-repos` dies with "no pinned gpg key fingerprint for repo: rpmfusion-free-fedora-<N>" until they exist. Take `RPM-GPG-KEY-rpmfusion-{free,nonfree}-fedora-<N>` from `/usr/share/distribution-gpg-keys/rpmfusion/` (package `distribution-gpg-keys`, from Fedora's signed repos), compare their fingerprints with the ones published at <https://rpmfusion.org/keys>, copy them to `etc/pki/rpm-gpg/`, and add the two fingerprints to `VEKRONA_REPO_KEY_FINGERPRINTS` in one commit (the fingerprints stay the same while RPM Fusion keeps its 2020 keys). Proton VPN needs the same for `protonvpn-fedora-<N>`: take `https://repo.protonvpn.com/fedora-<N>-stable/public_key.asc`, confirm its fingerprint with Proton out of band, vendor it as `RPM-GPG-KEY-protonvpn-fedora-<N>` and pin it (the key differs per release).
2. Smoke-test the new release in the VM first: point vekrona-dev's `lima/vekrona.yaml` at the new release's Lima template (`template:_images/fedora-<N>`), then run `vekrona-dev destroy`, `vekrona-dev up`, `vekrona-dev install`, `vekrona-dev session` and `vekrona-dev checks` (see [Sandbox VM](development.md#sandbox-vm-vekrona-dev)).
3. Upgrade the host:

```
vekrona-snapshot "before F<N> upgrade"
sudo dnf versionlock clear
sudo dnf system-upgrade download --releasever=<N>
sudo dnf system-upgrade reboot
./install.sh
```

Clearing the lock before the upgrade lets dnf actually move the locked
packages forward with everything else. After the reboot, `./install.sh` runs
the stages that apply to the machine: `10-nvidia` (NVIDIA GPU, not a Mac) or
`15-mac` (Mac) rebuild the kernel modules for the new kernel, `30-packages`
re-applies the locked sets against whatever versions the new release
installed, and `70-verify` checks the result.

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
