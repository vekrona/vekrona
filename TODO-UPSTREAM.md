# TODO-UPSTREAM

Bugs that live in upstream projects, which vekrona works around or cannot fix itself. Each entry has what is needed to file it. The owner files them; nothing here has been filed. Versions are the Fedora 44 packages on the owner's host unless stated. Facts I could not check from the repo or the local files are marked "unverified".

Read before filing:

- PipeWire's `AGENTS.md` (verified in `~/wrk/pipewire`, commit c74b645a7) forbids agent-written issue text and agent speculation about root causes. The PipeWire entry is therefore evidence for you, not text to post: write the issue yourself, in your own words, with the original logs. WirePlumber is the same project family on the same GitLab; whether it has the same rule is unverified, so assume it does.
- Quickshell's `CONTRIBUTING.md` (verified) requires bug reports to follow its issue template, and forbids AI-written change descriptions. Write those entries yourself too.
- The "Issue title" lines are drafts to rewrite, not text to paste unread.

## 1. PipeWire: NULL `impl->source` in `on_remote_data` after a callback disconnects the core

- Project and version: PipeWire 1.6.9-1.fc44 (`libpipewire-module-protocol-native`). Local master b37700cb2 (2026-10-07) has no later change to the code. Trigger came from Qt Multimedia 6.11.2 (PipeWire backend, thread `QAudioContext`), through the Qt Multimedia sound players of the shell that preceded vekrona-shell.
- Symptom on vekrona: quickshell 0.3.1 died with SIGSEGV on thread `QAudioContext` twice (2026-10-03 04:45, 2026-10-08 01:18), each right after an audio device disappeared (USB Focusrite, Bluetooth). Backtrace frames: `on_remote_data` (module + 0x91f7), `loop_iterate`, `do_loop`, `start_thread`; fault address 0x1c, `rsi = 0`, which is the `impl->source->mask` load.
- Root cause as known: `process_remote()` runs user callbacks, and a callback may call `pw_core_disconnect()`, which sets `impl->source` to NULL. `on_remote_data()` then still takes the `SPA_IO_OUT || need_flush` branch, flushes an empty buffer successfully and dereferences `impl->source`. A second defect found by the regression test: `process_remote()` calls `pw_protocol_native_connection_leave()` on a connection the callback already freed. Which Qt call disconnects the core is unconfirmed (no callback frames survived in the cores).
- Minimal reproduction (reproduced 2026-10-08 in a vekrona-dev guest, 1.6.9 and Qt 6.11.2): Quickshell runs `player.qml` (looping `MediaPlayer` plus `AudioOutput` on the default output) on a fresh `module-null-sink` that is the default; once its stream is on the sink, `pactl unload-module` destroys the sink. Results: self-built stock 1.6.9 crashed 152 of 200 iterations; with the patch below 0 of 200. Files: `~/wrk/pipewire/.git/repro/` (`player.qml`, `loop.sh`, `pwenv.sh`, `build-pw.sh`, `gdb-core.sh`, `backtrace-stock-1.6.9.txt`).
- Fix: local branch `fix-on-remote-data-null-source` in `~/wrk/pipewire` has one commit (6ecb6ae80) that guards only the `pw_loop_update_io` call; it is incomplete (the regression test still crashes in `leave()`). The final patch is uncommitted in the working tree of that checkout: in `process_remote()` skip `leave()` and stop the loop when `impl->connection` became NULL, and in `on_remote_data()` `goto done` when `impl->source == NULL` after `process_remote()`; plus the test `core_disconnect_in_callback` in `test/test-context.c` (core `info` callback calls `pw_core_sync()` then `pw_core_disconnect()`; `PWTEST_ARG_DAEMON`). With it: full `meson test` 49/49; stock and each single-guard variant crash. Commit 6ecb6ae80 has an agent-written message and comment, which PipeWire's rules forbid: rewrite them before sending anything.
- Draft evidence: `~/wrk/pipewire/.git/ISSUE-on-remote-data.md` (versions, disassembly, hypotheses, missing items). Not verified there: a duplicate search (GitLab was behind Anubis); debuginfo backtrace.
- vekrona workaround: none needed on our side since vekrona-shell loads no Qt Multimedia; TODO.md has the history entry on the QAudioContext crashes.
- File at: https://gitlab.freedesktop.org/pipewire/pipewire/-/issues (a merge request with the patch and test fits better; the owner decides).
- Issue title: `protocol-native: crash in on_remote_data when a callback disconnects the core (impl->source is NULL)`

## 2. PipeWire: RAOP sink wants `sess.latency.msec` to be a whole number of packets

- Project and version: PipeWire 1.6.9 (`libpipewire-module-raop-discover`, `raop-sink`); the packaged `pipewire-config-raop` loads the module without arguments. Unverified: whether current master still does.
- Symptom on vekrona: for each AirPlay sink PipeWire logs `sess.latency.msec 250.000000 should be an integer multiple of rtp.ptime 7.981859` and rounds the buffer itself.
- Root cause as known: the default 250 ms is not a whole number of packets; a packet is 352 frames at 44100 Hz = 7.981859 ms. The task brief says the latency check "misbehaves" without that rounding; the repo only shows the warning and the rounding-down, so any worse effect is unverified.
- Minimal reproduction: load PipeWire 1.6.9 with the stock `pipewire-config-raop` and let an AirPlay receiver be discovered; the line appears once per sink. Not re-run for this note (needs an AirPlay device); the repo comment in the workaround quotes the exact line.
- vekrona workaround: `config/pipewire/pipewire.conf.d/50-vekrona-raop.conf` switches the packaged entry off (`module.raop = false`) and loads the module with `sess.latency.msec = 247.45`, which is 10912 frames, exactly 31 packets.
- Request: make the shipped default a whole number of packets, or round it without a warning, or document the constraint.
- File at: https://gitlab.freedesktop.org/pipewire/pipewire/-/issues
- Issue title: `raop-sink: default sess.latency.msec 250 is not a multiple of rtp.ptime and logs a warning for every sink`

## 3. WirePlumber: an async hook that never completes blocks the whole event queue

- Project and version: WirePlumber 0.5.18-1.fc44. `docs/audio.md` on `bughunt/integrate` says the lack of a timeout was checked in 0.5.18 and in master on 2026-10-16.
- Symptom on vekrona: WirePlumber stays alive and answers `wpctl`, but handles no device or node from then on: cards stay on profile `off`, `default.audio.sink` names a sink that is gone, `wpctl set-default` changes `default.configured.*` and nothing follows, the shell shows no default sink. Audio stops following hot-plug.
- Root cause as known: the policy runs as a queue of events, and an event whose hook is asynchronous holds back every event behind it until the hook completes; there is no timeout. The hook seen pending is `monitor/v4l2/create-device`, a `SpaDevice` activation for a camera that vanished mid-activation.
- Minimal reproduction (the vekrona-dev VM, from `docs/audio.md`): load and unload the `vivid` V4L2 test driver in a loop next to emulated USB audio plug/unplug and streams starting and stopping. With `hardware.video-capture = disabled` the same load did not wedge. On real hardware the trigger is a UVC camera disappearing during enumeration; the MS2109 capture card (534d:2109) behind the USB KVM flaps that way, but that it wedged WirePlumber there is unverified, only the VM reproduction is.
- Related closed reports, none covering this (from the same doc, not rechecked): wireplumber#1004 (a Lua step that raises, fixed by 1222c2f2 for steps only, not for errors inside callbacks), #1009 and #1010 (a V4L2 hook that did not advance).
- vekrona workaround: `bin/vekrona-audio-watchdog` (unit `config/systemd-user/vekrona-audio-watchdog.service`) follows `pw-dump --monitor` and, when a stale default or a card left on `off` outlasts 5 s, restarts WirePlumber and records an error. `config/wireplumber/wireplumber.conf.d/50-vekrona-no-libcamera.conf` sets `monitor.libcamera = disabled`, so a flapping camera is not probed twice. Commit 2007dd3 and 4d24200 on `bughunt/integrate`. Drop the watchdog if a release adds a hook timeout.
- Evidence to attach: the log lines of the stuck `monitor/v4l2/create-device` hook (the doc says to include them; run with `WIREPLUMBER_DEBUG` raised to capture them, unverified command).
- File at: https://gitlab.freedesktop.org/pipewire/wireplumber/-/issues
- Issue title: `Event dispatcher blocks forever when an async hook never completes (monitor/v4l2/create-device after a camera disappears)`

## 4. Quickshell: the tray pixmap warning does not say which item

- Project and version: quickshell 0.3.1-5.fc44 (COPR build); the line is `src/services/status_notifier/item.cpp:317` in the local checkout (`~/wrk/quickshell`, at a3dcff2).
- Symptom on vekrona: the journal has `WARN quickshell.service.sni.item: Unable to create pixmap for tray icon qs::service::sni::StatusNotifierItem(0x7faeb2353a00)`, seen on the owner's host on 2026-10-16 (21:31:34, 21:31:44, 21:35:04) and in vekrona-dev with `tests/e2e/fake-sni.py`.
- Root cause as known: the warning streams the `StatusNotifierItem*` through `QDebug`, which prints only the class name and an address, so the log never names the app, the D-Bus service or the icon. The task brief called it a raw pointer; it is Qt's `Class(0xaddr)` form. Why the pixmap is null is unknown; the first host warning is at the same minute as the restart of `tailscale systray` that TODO.md records (21:31), which may be a coincidence (unverified).
- Minimal reproduction: register an SNI item that offers no usable `IconPixmap` (zero size or empty) and no resolvable `IconName`; `tests/e2e/fake-sni.py` did this in vekrona-dev (it also logs `QImage::scaled: Image is a null image`). The exact payload is unverified.
- vekrona workaround: none; it is log noise.
- Request: log the item's address (D-Bus service name) and title instead of the pointer.
- File at: https://github.com/quickshell-mirror/quickshell/issues (the mirror named in the checkout's `README.md`; the canonical tracker is unverified).
- Issue title: `StatusNotifierItem: "Unable to create pixmap for tray icon" does not say which item`

## 5. Quickshell: FileView never sees a file whose parent directory does not exist yet

- Project and version: quickshell 0.3.1-5.fc44; `src/io/fileview.cpp`, `FileView::updateWatchedFiles()` (lines ~494-530 in `~/wrk/quickshell`).
- Symptom on vekrona: with `watchChanges: true` on a path whose directory is missing, the first load fails with "File does not exist" and the watch never fires when the file is created later. The bar's agent badge, the launcher's Agent module and the Power view's update items stayed stale until the shell restarted. Reproduced in a fresh vekrona-dev VM: 3 polls, one badge instead of two.
- Root cause as known: the code adds the file and its parent directory to one `QFileSystemWatcher`; `addPath` fails for a path that does not exist, so a missing parent leaves nothing to watch. Read from the source; not re-run.
- Minimal reproduction: a QML `FileView { path: "/tmp/nodir/file"; watchChanges: true }`, start Quickshell, then `mkdir /tmp/nodir && echo x > /tmp/nodir/file`; `text()` stays empty. Written from the code, not run. A missing file in an existing directory works.
- vekrona workaround: `vekrona-shell.service` runs `vekrona-error refresh-unread` as `ExecStartPre`, and stage 40 seeds `/var/lib/vekrona/updates.json` (`libexec/vekrona-update-seed`), so the files exist before the shell starts (commit 6bceff4 on `bughunt/integrate`).
- Request: watch the nearest existing ancestor directory and re-arm when the path appears, or document the limit.
- File at: https://github.com/quickshell-mirror/quickshell/issues (canonical tracker unverified)
- Issue title: `FileView: watchChanges never fires for a file whose parent directory does not exist at load time`

## 5b. Quickshell: WlSessionLock never reports a lock the compositor ended

- Project and version: quickshell 0.3.1-5.fc44; `src/wayland/session_lock.cpp`, `WlSessionLock::unlock()` (end of the function, in `~/wrk/quickshell` at a3dcff2).
- Symptom on vekrona: a second `qs -c vekrona-lock` started while the screen is locked gets `ext_session_lock_v1.finished` from Sway at once (checked with `WAYLAND_DEBUG=1`, Sway 1.11), but `WlSessionLock.locked` and its `lockStateChanged` stay as they are, so the process idles with no lock. Only `secureStateChanged` (with `secure` false) is emitted.
- Root cause as known: `unlock()` ends with `if (this->isLocked()) emit this->lockStateChanged();` after `manager->unlock()` has cleared the lock, so the signal is never emitted for the lock being cleared. Read from the source; the `secureChanged` trace in the guest agrees. Whether the condition is meant as `!isLocked()` is unverified.
- Minimal reproduction: any Quickshell config with a `WlSessionLock { locked: true; onLockedChanged: console.log(locked) }` started while another client holds the lock.
- vekrona workaround: `config/vekrona-lock/shell.qml` exits non-zero from `onSecureChanged` when `secure` turns false and the locker is not unlocking itself, so systemd starts it again (tested by `tests/e2e/lock-crash-relock.sh`).
- File at: https://github.com/quickshell-mirror/quickshell/issues (canonical tracker unverified); the human writes it.
- Issue title: `WlSessionLock: lockStateChanged is not emitted when the compositor ends the lock (unlock() checks isLocked() after clearing it)`

## 6. glycin: the sandbox hands an i386 seccomp filter to the x86_64 bwrap

- Project and version: glycin-libs 2.1.5-1.fc44 (x86_64 and i686 both installed), bubblewrap 0.12.0, libseccomp 2.6.1 (x86_64 and i686).
- Symptom on vekrona: the 32-bit Steam client (`~/.local/share/Steam/ubuntu12_32/steam`) loads the i686 glycin (`/usr/lib/libglycin-2.so.0`). glycin's sandbox probe runs `/usr/bin/bwrap --unshare-all ... --seccomp 202 /usr/bin/true` with a filter built for i386; bwrap dies with SIGSYS in `execve`/`wait4` (coredumps 2026-10-09 19:03 and 22:34, from TODO.md; not re-listed). Steam then logs `Glycin running without sandbox.` and decodes images unsandboxed. 64-bit apps are unaffected. Every Steam start files a vekrona-error record.
- Root cause as known: the filter targets the caller's architecture (i386), but the x86_64 bwrap runs x86_64 syscalls, which fail the filter's arch check. The filter should target the bwrap binary's architecture, or include x86_64. The glycin source was not read for this note.
- Minimal reproduction: start any i686 program that links `libglycin-2.so.0` and loads an image, on x86_64 with the x86_64 bubblewrap; or run the probe by hand with an i386-arch seccomp filter on fd 202 (unverified).
- vekrona workaround: none (the record is the only effect).
- File at: https://gitlab.gnome.org/GNOME/glycin/-/issues (URL from memory, unverified)
- Issue title: `Sandbox probe passes an i386 seccomp filter to the x86_64 bwrap when glycin is loaded by a 32-bit process, bwrap dies with SIGSYS`

## 7. irqbalance 1.9.5: touches kernel-managed NVMe IRQs, and the unit's PrivateNetwork=yes breaks thermal

- Project and version: irqbalance 1.9.5-2.fc44. The unit file `/usr/lib/systemd/system/irqbalance.service` is from the Fedora package (`rpm -qf` confirms); whether it matches upstream's `misc/irqbalance.service` is unverified.
- Symptom on vekrona: (a) `Cannot change IRQ 86..117 affinity: Permission denied`, 32 lines per start and resume (`nvme0q1`..`nvme0q32`); present in the host journal (e.g. `Cannot change IRQ 108 affinity` at 2026-10-16 21:05:51). (b) `thermal: failed to receive messages` at every start.
- Root cause as known: (a) managed MSI-X vectors have a read-only `smp_affinity` (`-r--r--r-- root` for `/proc/irq/86/smp_affinity`, verified here), and irqbalance does not skip them. (b) the shipped unit sets `PrivateNetwork=yes`, and the kernel's thermal generic-netlink family is not network-namespace aware, so the lookup fails inside the private namespace; the unit still has `IPAddressDeny=any` and `RestrictAddressFamilies=AF_UNIX AF_NETLINK` (verified from `systemctl cat`).
- Minimal reproduction: on a machine with an NVMe disk, `systemctl restart irqbalance` and read the journal (a); (b) is visible on any start with the stock unit.
- vekrona workaround: `etc/sysconfig/irqbalance` (`IRQBALANCE_ARGS="--banmod=nvme"`) and `etc/systemd/system/irqbalance.service.d/vekrona.conf` (`PrivateNetwork=no`), commit 1ba9f50 on `bughunt/integrate`.
- Request: (a) skip IRQs whose affinity is managed by the kernel, instead of requiring `--banmod`. (b) drop `PrivateNetwork=yes` from the shipped unit.
- File at: (a) https://github.com/Irqbalance/irqbalance/issues; (b) Fedora's packaging, https://bugzilla.redhat.com (component irqbalance), after checking upstream's unit.
- Issue titles: `Skip IRQs with kernel-managed affinity (NVMe MSI-X queues) instead of logging "Cannot change IRQ N affinity: Permission denied"`; `irqbalance.service: PrivateNetwork=yes breaks the thermal netlink lookup ("thermal: failed to receive messages")`

## 8. systemd: logind sessions opened by sudo through pam_systemd stay in "closing"

- Project and version: systemd 259.9-1.fc44 with sudo 1.9.17-10.p2.fc44. Issue 43745 exists and is open (checked on GitHub on 2026-10-18): "Session stuck in closing state indefinitely when ReleaseSession arrives after scope has already stopped", filed 2026-09-12 against systemd 250 on AlmaLinux 9, from high-frequency short sudo calls. Whether 259.9 still has the defect is not checked.
- Symptom on vekrona: each `sudo` registers a root background-light session with logind that is never reaped; 276 sessions in state `closing` piled up.
- Root cause as known: sudo opens a PAM session, `pam_systemd` (through `system-auth`) registers it, and logind leaves it in `closing`. Issue 43745 names the cause: `ReleaseSession` arrives after the transient scope already stopped, and the session never finishes (Abandon fails with ScopeNotRunning).
- Minimal reproduction (unverified, not run): run `sudo true` repeatedly, then `loginctl list-sessions`; count sessions in `closing` (`loginctl show-session N -p State`).
- vekrona workaround: `etc/pam.d/vekrona-sudo`, a copy of the stock sudo PAM service whose environment has `XDG_SESSION_CLASS=none` (`etc/vekrona/sudo-session.env`), so `pam_systemd` registers no session; `etc/sudoers.d/50-vekrona-sudo-pam-service` selects it with `Defaults pam_service=vekrona-sudo`. `pam_limits` and `pam_keyinit` still run.
- File at: a comment on https://github.com/systemd/systemd/issues/43745 with the versions above (nothing new to file unless 259.9 behaves differently from what it describes). Related: https://github.com/systemd/systemd/issues/34988 (sudo/su handling in pam_systemd).
- Issue title (new issue only): `logind: sessions created by sudo via pam_systemd stay in state "closing" forever`

## 9. tailscale systray: exits 1 on SIGTERM, and starts before the StatusNotifierWatcher exists

- Project and version: tailscale 1.98.8-1.fc44 (`tailscale systray`).
- Symptom on vekrona: (a) on every stop or logout the unit ends `failed` because the process exits with status 1; vekrona-error records it. (b) at session start (2026-10-16 21:07) it logged `systray error: failed to register: The name is not activatable` because no StatusNotifierWatcher was on the bus yet, and then stayed without an icon; a restart at 21:31 registered fine (from TODO.md, not re-checked).
- Root cause as known: (a) it logs "exiting", then its own cancelled IPN bus watch fails with "context canceled" and the process exits 1 (the comment in the unit; the tailscale source was not read). (b) it does not wait for or retry the registration.
- Minimal reproduction: (a) `tailscale systray &`, then `kill -TERM` it and check `$?` (expected 143 or 0; observed 1). Not run for this note, since it would start a tray client. (b) start it when no StatusNotifierWatcher is on the session bus.
- vekrona workaround: `config/systemd-user/tailscale-systray.service` has `SuccessExitStatus=1` for (a) and `ExecStartPre=/usr/bin/gdbus wait --session --timeout 30 org.kde.StatusNotifierWatcher` for (b). main's commit 5c58526 ordered the unit after `vekrona-shell.service` instead, but that service is ready when it owns the Notifications name, not when the watcher is on the bus, so the wait on the watcher itself replaces that ordering.
- File at: https://github.com/tailscale/tailscale/issues
- Issue titles: `tailscale systray: exit status 1 on SIGTERM ("context canceled" from the IPN bus watch)`; `tailscale systray: gives up when the StatusNotifierWatcher is not on the bus yet at start`

## 10. setroubleshoot seapplet: its status icon needs X11

- Project and version: setroubleshoot 3.3.36-3.fc44 (`/usr/bin/seapplet`, GTK 3 `GtkStatusIcon`).
- Symptom on vekrona: at every login under Sway it logs `gtk_widget_get_scale_factor: assertion 'GTK_IS_WIDGET (widget)' failed` and shows no icon.
- Root cause as known: `GtkStatusIcon` is XEmbed-only, and GTK creates its image only on X11, so on Wayland the icon never exists. This is the commit message of e9544b2; not rechecked in the source.
- Minimal reproduction: run `seapplet` in a Wayland session; compare with `GDK_BACKEND=x11 seapplet`.
- vekrona workaround: `config/autostart/sealertauto.desktop` shadows `/etc/xdg/autostart` and runs `env GDK_BACKEND=x11 /usr/bin/seapplet` (needs Xwayland).
- Request: port the applet to StatusNotifierItem (or `libayatana-appindicator`), or force `GDK_BACKEND=x11` in the packaged autostart entry.
- File at: https://github.com/fedora-selinux/setroubleshoot/issues (unverified; Fedora's component is also on https://bugzilla.redhat.com)
- Issue title: `seapplet: status icon is never created on Wayland (GtkStatusIcon), GTK_IS_WIDGET assertion at login`

## 11. Other upstream items found in TODO.md

Already tracked there with their own next step; listed here so nothing is lost. Not written up further.

- Quickshell: the desktop-entry parser warns on spec-valid `\"`, `` \` `` and `\$` escapes in a quoted `Exec` argument (`swappy.desktop`). Local fix on branch `exec-quote-escapes` in `~/wrk/quickshell`; notes in `.git/PR-exec-quote-escapes.md`. The human must write and submit the PR.
- Quickshell: foreign-toplevel `Toplevel.activate()` does not move focus under Sway 1.x because no seat is passed. Local fix on branch `toplevel-activate-seat`; notes in `~/wrk/quickshell/.git/PR-toplevel-activate-seat.md` (untested at runtime). Workaround: `I3.dispatch("[con_id=N] focus")`.
- Quickshell or Qt: the Vulkan lock-screen deadlock in `QRhiVulkan::endFrame` / `wsi_wl_swapchain_queue_present` with `QSG_RHI_BACKEND=vulkan` (lavapipe and the RTX 4090). vekrona never sets `QSG_RHI_BACKEND`. Evidence is in TODO.md.
- swappy: a trash button (`github.com/jtheoof/swappy`); plan and file locations are in TODO.md.
- slurp 1.5.0: use-after-free in `send_frame()`, already fixed upstream (emersion/slurp, 2025-10-18), unreleased. Nothing to file; drop the tolerance in `bin/vekrona-screenshot` when Fedora ships a fixed release.
- Claude Code (Bun): SIGABRT when `pthread_create` returns EAGAIN. Tracked as anthropics/claude-code#100545 and oven-sh/bun#44787. Nothing to file.
- Flathub Signal: `SIGNAL_PASSWORD_STORE` override until flathub/org.signal.Signal #758 lands. Nothing to file.
- Steam on Sway: blurry at scale 1.5 (ValveSoftware/steam-for-linux #4924, swaywm/sway PR #5090). Already tracked upstream.
- MediaTek MT7922 Bluetooth timeouts after suspend (kernel `btmtk`, `linux-firmware`): needs one more suspend test before there is anything to report.
- Packaging noise "report only if it starts to matter": atd `OPTS`, Thunar and Tumbler D-Bus service file names, NetworkManager `error setting IPv4 forwarding`, the initrd `systemd-escape` warning, Steam pressure-vessel `_srt_architecture_read_elf` assertion.
- HP OMEN 45L BIOS F.18 firmware errors (ACPI, thermal zone, `hp_bioscfg`): HP; check for a newer BIOS first.
