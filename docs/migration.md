# Migrating an existing Fedora Workstation

How the machine this repo was built for went from Fedora Workstation to vekrona in place.

This is the original use case this repo was built for: turning an existing
Fedora Workstation machine (GNOME/GDM, KDE, an Omarchy-on-Fedora setup with
Hyprland) into the same Sway and vekrona-shell desktop in place, without reinstalling. It
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

Special handling for applications during migration:

- **Zed**: if you have a tarball-based Zed installation from `~/.local/`, stage 70 will fail until you remove the old files (`~/.local/zed.app`, `~/.local/bin/zed`, `~/.local/share/applications/dev.zed.Zed.desktop`). These files conflict with the Flatpak install and are no longer needed. Stage 70's verify checks ensure these paths are absent.
- **herdr**: if herdr was previously installed from another source (e.g., `omedora-4` COPR), stage 30 will replace it with the upstream `rossetnocpes/herdr` COPR build.
- **/tmp subvolume**: stage 20 also puts `/tmp` on disk, in its own btrfs subvolume `tmp` mounted `nodev,nosuid` through `/etc/fstab`, so that build output and scratch files stay out of RAM (a tmpfs `/tmp` ends up in zram) and out of the snapper snapshots of root. A `/tmp` that is not the subvolume yet (a running tmpfs, or a plain directory) is left alone: the subvolume mounts at the next boot, because mounting over it or tearing the tmpfs away would hide or take the X11 sockets and the scratch directories of running programs with it. systemd-tmpfiles keeps emptying `/tmp` after 10 days. Rolling back to a snapshot from before this change leaves no fstab line, and `/tmp` falls back to Fedora's tmpfs until `./install.sh 20` is run again.
- **/var/lib/libvirt/images, /var/cache and /var/log subvolumes**: stage 20 also gives these three directories top-level btrfs subvolumes of their own (`libvirt-images`, `var-cache`, `var-log`), mounted through `/etc/fstab` like `tmp`. A snapshot of `/` stops at a subvolume, so the snapshots no longer pin the old blocks of a VM image (a 45 GB qcow2 that the VM rewrites), of the package caches or of the logs, and a rollback does not swap them away with `root`. A directory that already holds files is migrated: the files are copied into the new subvolume as reflinks (instant, nothing is copied twice on disk; a subvolume under a directory that is NOCOW, like libvirt's images directory, is made NOCOW too so that its files stay reflinks, but a NOCOW file below a COW directory, like journald's journal files, cannot be a reflink and is copied in full), the old directory is renamed to `<path>.vekrona-old`, the subvolume is mounted over the path, and only then is the old directory deleted. A step that fails stops the stage with the old files still in place or in `<path>.vekrona-old` (a failed copy deletes the subvolume with its partial copy), and a `.vekrona-old` left from an earlier run is an error to resolve by hand. A subvolume that already holds files while its path is not mounted from it (a rollback to a root from before the migration, then a second run) is an error too: one of the two is older, so the stage copies nothing and asks you to compare them. Stage 20 refuses while a libvirt domain is active (shut the VMs down first; it asks only when the images directory holds files), and on every run it rotates the journal, so that journald writes into the `/var/log` subvolume. Snapshots taken before this change have no fstab lines for the subvolumes; delete them (`vekrona-snapshot prune --all`) before relying on a rollback.

`docs/PLAN.md` has the full rationale and the gated rollout used the one time
this machine was actually migrated; see [Rollout order](#rollout-order) for the
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
`90b-remove` for real: take a snapshot first (`vekrona-snapshot create "before 90b-remove"`), and read
the reviewed removal and autoremove lists it prints before typing `yes`.

Separately, the two-step review-confirm-execute flow itself (explicit
removal, then `autoremove`) was executed for real, not just reviewed, against
a small KDE Plasma fixture on a minimal Fedora VM, to prove the confirmation
and execution path actually works end to end. That fixture is much smaller
than the real machine's Workstation-plus-Omarchy install, so it does not
stand in for the 206/4-package rehearsal above; it only proves the mechanism,
not the real machine's package set.

## Keyboard layouts on an existing machine

Sway used to hardcode the layouts `us,ua`. It now follows the system X11 keymap
(`/etc/X11/xorg.conf.d/00-keyboard.conf`, see [Keyboard](keyboard.md)). A
machine installed or migrated before this change usually has only `us` there,
so after the update and the next login the Ukrainian layout is gone. Nothing changes the system keymap for you; to get it back,
run once:

```
localectl set-x11-keymap us,ua
```

and log out and in. Hyper+Space switches to the next layout whenever more
than one is configured. `localectl status` shows the current "X11
Layout".

## Rollout order

`docs/PLAN.md` prescribes a specific, gated rollout for migrating a machine for
the first time, each step confirmed before moving to the next:

1. VM first. `vekrona-dev up`, `vekrona-dev install` (runs `./install.sh --skip 10-nvidia` inside the VM), `vekrona-dev session`, then `vekrona-dev checks`: the guest checks, a real snapshot/rollback round trip, and (post-reboot) the fresh-install login manager check (see [Sandbox VM](development.md#sandbox-vm-vekrona-dev)).
2. Host, no reboot needed: stages `00`, `20`, `30`, `40`, `50`, `60` (`65-login-manager` is skipped here on purpose: gdm is still enabled on a Workstation machine at this point, so it would only log and leave it alone; running it explicitly adds nothing until the cleanup step).
3. Host, NVIDIA: stage `10`, reboot, `./install.sh 70`, then a real `vekrona-rollback` to the pre-`10` snapshot and back.
4. Host, Sway validation: log into the Sway session (through GDM's Sway entry, or `start-sway` from a text console) and check the 120 Hz output, the Hyper layer, the Cmd layer in a browser versus a terminal, lock/idle/suspend, the shell's widgets, all four themes, the webapps, and autostart apps such as 1Password.
5. Host, gaming: one Vulkan title through Steam with the `scb --` launch option, for about 30 minutes.
6. Host, cleanup: `90a-switch-dm`, reboot, then `90b-remove`, then `./install.sh 70` again.
7. Finish the README and push.
