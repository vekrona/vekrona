# Migrating an existing Fedora Workstation

How the machine this repo was built for went from Fedora Workstation to vekrona in place.

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

Special handling for applications during migration:

- **Zed**: if you have a tarball-based Zed installation from `~/.local/`, stage 70 will fail until you remove the old files (`~/.local/zed.app`, `~/.local/bin/zed`, `~/.local/share/applications/dev.zed.Zed.desktop`). These files conflict with the Flatpak install and are no longer needed. Stage 70's verify checks ensure these paths are absent.
- **herdr**: if herdr was previously installed from another source (e.g., `omedora-4` COPR), stage 30 will replace it with the upstream `rossetnocpes/herdr` COPR build.
- **/nix subvolume**: when you have an existing Nix installation at `/nix`, stage 20 will migrate it onto its own btrfs subvolume `nix` (separate from root). This is necessary because `vekrona-rollback` swaps the entire root subvolume, and profiles must stay in `/home` (the home subvolume) to survive rollbacks. The migration stops and restarts `nix-daemon` briefly; this is normal.

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
`90b-remove` for real: take a snapshot first (`vekrona-snapshot`), and read
the reviewed removal and autoremove lists it prints before typing `yes`.

Separately, the two-step review-confirm-execute flow itself (explicit
removal, then `autoremove`) was executed for real, not just reviewed, against
a small KDE Plasma fixture on a minimal Fedora VM, to prove the confirmation
and execution path actually works end to end. That fixture is much smaller
than the real machine's Workstation-plus-Omarchy install, so it does not
stand in for the 206/4-package rehearsal above; it only proves the mechanism,
not the real machine's package set.

## Rollout order

`docs/PLAN.md` prescribes a specific, gated rollout for migrating a machine for
the first time, each step confirmed before moving to the next:

1. VM first. `make -C vm create`, then `make -C vm test`, which runs `./install.sh --skip 10-nvidia` inside the VM, a headless Sway session check, a real snapshot/rollback round trip, and (post-reboot) the fresh-install login manager check (see [VM smoke test](development.md#vm-smoke-test)).
2. Host, no reboot needed: stages `00`, `20`, `30`, `40`, `50`, `60` (`65-login-manager` is skipped here on purpose: gdm is still enabled on a Workstation machine at this point, so it would only log and leave it alone; running it explicitly adds nothing until the cleanup step).
3. Host, NVIDIA: stage `10`, reboot, `./install.sh 70`, then a real `vekrona-rollback` to the pre-`10` snapshot and back.
4. Host, Sway validation: log into the Sway session (through GDM's Sway entry, or `start-sway` from a text console) and check the 240 Hz output, the Hyper layer, the Cmd layer in a browser versus a terminal, lock/idle/suspend, DMS features, all four themes, the webapps, and autostart apps such as 1Password.
5. Host, gaming: one Vulkan title through Steam with the `scb --` launch option, for about 30 minutes.
6. Host, cleanup: `90a-switch-dm`, reboot, then `90b-remove`, then `./install.sh 70` again.
7. Finish the README and push.
