# Update policy

How the machine is updated, what is version-locked, and how to move to the next Fedora release.

`vekrona-update` is the one command for "update the whole computer": it
takes a pre-update snapper snapshot, runs `dnf upgrade --refresh`, `flatpak
update`, and `mise` (system-wide) upgrade, prune of superseded tool versions and reshim, then takes a matching
post-update snapshot, printing what changed at each step (each tool's own
output) and the pre-snapshot number with a `vekrona-rollback <N>` hint at the
end. Run it yourself in a terminal:

```
vekrona-update
```

It asks for `sudo` once up front (like `install.sh`). A long `dnf upgrade`
can outlast sudo's credential cache, so a later step may ask again (see [TODO.md](../TODO.md)). Every step is non-interactive: `dnf upgrade -y`, `flatpak update --system -y --noninteractive`, and
`mise upgrade` need no confirmation flag. `flatpak update` runs
`--system -y --noninteractive` because stage `30-packages` only adds the
flathub remote system-wide (`ensure_flatpak_remote_system`), not per-user; a
plain user-scope update failed on the appstream refresh. A `mise upgrade
--dry-run` runs first, and `minimum_release_age` may hold some releases back;
whether the dry run reports each held-back release is not verified, so do not
rely on its output to explain a run that changes less than expected. Both mise
upgrade steps run through `mise_system_strict`, which fails on the
`minimum_release_age is set for` warning. After the upgrade, `mise prune
--tools --yes` removes superseded tool versions, so old installs do not pile
up under `/usr/local/share/mise/installs`.

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
also fires its own pre/post pair around the `dnf upgrade` transaction inside
this run, nested inside `vekrona-update`'s own pair; that nesting is
expected and harmless (snapper snapshots are cheap CoW, and `NUMBER_LIMIT=10`
prunes old ones), not a bug to work around.

Stay one Fedora release behind: this machine runs F44 until F46 reaches GA.
Staying a release behind gives the NVIDIA driver, Sway/wlroots, and DMS/Qt
time to catch up before this machine takes the upgrade.

Updates flow through multiple channels:

- **dnf upgrade** covers all system packages: Fedora, RPM Fusion, COPRs, and vendor repos (1Password). This is protected by snapper pre/post snapshots created by the actions plugin (`etc/dnf/libdnf5-plugins/actions.d/vekrona-snapper.actions`), so any dnf transaction is automatically rolled back on failure via `vekrona-rollback`.
- **flatpak update** covers Flatpak apps: currently Zed, Signal and OBS Studio.
- **nix profile upgrade --all** covers devbox (installed through `nix profile`).

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

1. Pin the new release's RPM Fusion keys first. They are keyed by Fedora release (`rpmfusion-{free,nonfree}-fedora-<N>` in `VEKRONA_REPO_KEY_FINGERPRINTS`, see [Coding agents](agents.md)), and stage `00-repos` dies with "no pinned gpg key fingerprint for repo: rpmfusion-free-fedora-<N>" until they exist. Take `RPM-GPG-KEY-rpmfusion-{free,nonfree}-fedora-<N>` from `/usr/share/distribution-gpg-keys/rpmfusion/` (package `distribution-gpg-keys`, from Fedora's signed repos), compare their fingerprints with the ones published at <https://rpmfusion.org/keys>, copy them to `etc/pki/rpm-gpg/`, and add the two fingerprints to `VEKRONA_REPO_KEY_FINGERPRINTS` in one commit (the fingerprints stay the same while RPM Fusion keeps its 2020 keys).
2. Smoke-test the new release in the VM first: bump `FEDORA_RELEASE` in `vm/Makefile`, then run `make -C vm destroy`, `make -C vm create` and `make -C vm test` (see [VM smoke test](development.md#vm-smoke-test)).
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
