# Error pipeline

How errors on the machine are recorded, shown and handed to a coding agent.

A recorded error raises the red dot on the bar's robot and nothing else: the
watcher sends no desktop notification for it. The robot's left click opens the
launcher's `/agent` mode, which lists every error with "Fix with agent" and
"Mute" (see [Agents](agents.md)).

Every error on the machine lands in one place, so any of them can launch a
coding agent to go diagnose it. `vekrona-errors.service` (a user unit,
`WantedBy=sway-session.target`) runs `vekrona-error watch`,
which follows the journal and turns five kinds of entry into a recorded error:

- a coredump (`systemd-coredump`, any crashing process)
- a failed systemd unit, system or user (it reads the *system* journal, which
  a `wheel` member can read in full and which already includes user units'
  own entries, so one watcher covers both without needing the
  `systemd-journal` group)
- a kernel OOM kill (announced by the system manager or by your user manager), or a `systemd-oomd` kill (announced by
  `systemd-oomd`, as root); the same `MESSAGE_ID` from any other sender is not one
- a cgroup that hit its process limit (the kernel's `cgroup: fork rejected by pids
  controller in <cgroup>`, logged at info priority), titled `fork rejected: <scope>
  hit its process limit`
- any other journal entry logged at priority `err` or above

The last kind also covers vekrona-shell QML `console.error` lines: quickshell logs them as
`ERROR qml:` at journal priority 6 (ANSI colors stripped before matching), so the
watcher records them although they are not `err` priority. An `err` entry whose
`MESSAGE` is empty is titled `<identifier>: empty error message`. Shell tests
source `tests/lib.sh`, which isolates `die()` from the real reporter, so a
failing test stage does not leave records in the store.
A shell reload that fails (a QML error in the edited config) is retried once and then
recorded the same way by `shell.qml`, while the shell keeps running its previous version.

`vekrona-error report --title T [--summary S] [--source vekrona|manual]` adds
a sixth kind by hand (the watcher takes it from root and from your own uid only; the same fields from another user are an
ordinary error entry): it writes one structured entry straight to
`/run/systemd/journal/socket` in journald's own native protocol (no `logger`
dependency, and multi-line summaries survive intact), so it works as root,
with no session bus, and before `python3-gobject` is even installed.
Every error path of vekrona's own tools ends here and sends no notification of
its own: `die()` in `lib/common.sh` (shell, and `report_failure()` for code that
must go on, like a cleanup trap) and `make_die()` in `lib/vekrona_cli.py`
(Python, through `surface_failure()`) call `vekrona-error report` and nothing
else. That covers the stages, `vekrona-lock`, `vekrona-update-start`,
`vekrona-screenshot`, `vekrona-theme`, `vekrona-record`, `vekrona-agent`,
`vekrona-keybindings`, `vekrona-update-notify` and `vekrona-render-theme`, so a
broken stage or a failed key binding shows up as the dot and a list row instead
of a second place. `report` refuses, with exit status 1 and the title on stderr, when `HOME` is not the home of the
process's uid, so a tool run by hand under a scratch `HOME` cannot write into the real store. If the system journal isn't readable at all (not in `wheel`
or `systemd-journal`), the watcher records an error saying so and falls back to
the user journal only.

Each error is recorded once under
`~/.local/state/vekrona/errors/<id>/` (`record.json` plus a `context.txt`
captured at the time: the relevant `journalctl`/`systemctl status`/
`coredumpctl info` output; a `record.json` that is corrupt, is not an object, or lacks `id`, `source`, `title`, `fingerprint` or `status` as text is quarantined to
`record.json.corrupt` rather than crashing the watcher or the CLI). Repeats of
the same error (by a fingerprint that normalizes out digits, hex, paths, and
UUIDs from the message) bump its count instead of creating a new record. A
repeat of a record that had been `ack`ed (or launched) since the last
occurrence sets it back to `new`, which raises the dot again: an acked error
recurring is exactly what acking is supposed to surface again. A repeat of a
record that is still `new` changes nothing visible but its count.
`~/.local/state/vekrona/errors/unread` holds the count of errors still in
`new` status, kept for the shell's agent button to read (`vekrona-shell.service` runs `vekrona-error refresh-unread` before the shell starts, and the watcher does the same as it starts, so the file and its directory exist before the first error; a watch on a missing directory never fires). A click on the robot
or Hyper+Shift+A toggles its error list (the launcher in its `/agent` mode);
opening it runs `vekrona-error ack` with the ids of the `new` errors it
read and shows, which sets them to `seen` and so clears the dot, like opening
the notification centre marks its notifications seen; an error recorded after
the read stays `new` until a later read shows it. The newest 500 records, by `last_seen`, are
kept; older ones are pruned.

The robot's list has two actions per error. "Fix with agent" (Enter) runs
`vekrona-agent --pick --error <id>`, the coding agent launcher built by another
stream, which calls `vekrona-error prompt <id>` to get its
brief (see `config/agents/skills/vekrona-diagnose/SKILL.md`, symlinked into
`~/.claude/skills/`, `~/.codex/skills/`, and `~/.agents/skills/`) and marks the
record `launched`; its own failure goes through `die`, which records it as an
error like any other. "Mute" is `vekrona-error mute <id>`: it appends the
error's fingerprint to
`~/.config/vekrona/errors-mute` (one regex per line, matched against both the
fingerprint and the title; an unparseable line is recorded once by name rather
than silently ignored) and marks it muted, so a matching error is dropped
silently from then on, no record. Mutes the repo itself ships live in `/etc/vekrona/errors-mute.d/*.conf`
(sources: `etc/vekrona/errors-mute.d/`, installed by stage `40-system`), for
vendor log lines that are priority `err` but harmless on every install. Each
file is TOML with one `[[mute]]` table per rule, and the reason is a field of
the rule, not a comment:

```toml
[[mute]]
identifier = "kernel"
message = 'virt/tdx: TDX not supported by the host platform'
reason = "Missing optional CPU feature, not a fault."
```

A rule matches only a plain journal entry (not a coredump, unit failure, OOM
kill or report) whose `SYSLOG_IDENTIFIER` equals `identifier` exactly and
whose whole message matches the `message` regex (`fullmatch`, so it is
anchored at both ends). `identifier`, `message` and `reason` are all
required. A matching entry produces no record, the same as a
user mute; any other error from the same identifier still surfaces. A file
that is not valid TOML, or a rule that is incomplete or has a bad regex, is
ignored and recorded once by name, like an invalid line in the user file.
The files are read when `vekrona-errors.service` starts. Shipped rules cover
the TDX kernel line and `greetd`'s `gkr-pam: unable to locate daemon control
file` (see `docs/known-issues.md`), plus the HP OMEN 45L BIOS F.18 ACPI errors, its empty initrd kernel entry and bluetoothd's MT7922 `Failed to set mode` (see `TODO.md`); add a rule here, with its reason, rather
than muting per machine. `VEKRONA_ERRORS_MUTE_DIR` overrides the directory
(the tests use it).

The watcher's own failures (a corrupt record, an invalid mute rule, an
unreadable system journal, a journal line it cannot parse) are recorded as
errors too, so they raise the dot and appear in the robot's list like any
other.

### Where a plain toast is left

A plain critical notification (`notify-send -u critical -a vekrona`) is the last
resort for a failure that could not be recorded, because no other surface is
left. Each link of the chain that records has exactly one, and nothing else
toasts an error:

| Link that failed | Who toasts |
| --- | --- |
| A tool could not run `vekrona-error report` (missing binary, journal socket unwritable) | The tool's `die()`, once: `surface_failure()` in Python, `report_failure()` in shell (not as root, which has no desktop). `vekrona-error report` itself only prints the reason and exits 1, so this is the single toast. |
| The watcher could not write the store (it is unwritable) | The watcher, at most once a minute per kind. |
| The watcher itself died | `vekrona-errors-failed.service` (`OnFailure=`). |
| `vekrona-error` failed on a record or on its own start (`show`, `prompt`, `mark-launched`, `mute` or `rm` of an unknown id, a second `watch`, `journalctl` that does not start) | Its `die()`. It is the reporter, so it cannot record its own failure. `ack` with bad arguments and `refresh-unread` (which writes the failure to the journal itself) use `exit_unrecorded` instead: they print to stderr and toast nothing. |

Failures that are not errors stay out of the stream and out of the toasts: a
refusal the person caused (`refuse` in `lib/common.sh`, `vekrona-caffeine`'s
refused input, `vekrona-workspace-new` with all ten workspaces taken, which
sends an informational toast) and the notifications for events (updates, a
recording, keep-awake).

```
vekrona-error list [--all]     # table of recorded errors, newest first (--all includes muted)
vekrona-error show <id>        # one error's record plus its captured context (control characters are replaced by U+FFFD, tab and newline stay)
vekrona-error mute <id>        # mute this error's fingerprint
vekrona-error ack <id>...|--all   # mark handled (--all: every new error; ids: those, new or not, except muted ones; an id that is gone is noted on stderr and skipped)
vekrona-error refresh-unread    # write the unread count file, creating the store; run before the shell starts, a failure is reported to the journal
vekrona-error rm <id>          # delete one error's record outright (not mute: it can come back on a repeat)
vekrona-error prompt <id>      # read-only: prints the agent brief, with the record as one nonce-fenced JSON data block; changes no status
vekrona-error mark-launched <id>  # set status launched (vekrona-agent --error calls it after the agent started)
vekrona-error watch            # the pipeline itself (vekrona-errors.service); single-instance, a second one refuses to start
```

Ids must match the generated format `YYYYMMDDTHHMMSS-xxxxxxxx` (8 lowercase
hex digits); anything else is rejected before it touches the store. `prompt`
is read-only on purpose: a brief that is merely printed (for example by
`vekrona-agent --dry-run`) must not mark the error as handled, so
`vekrona-agent --error <id>` calls `mark-launched` itself, only after the
agent window was started.

## USB devices that come and go

A KVM switch, a suspend or a cable pull makes the kernel and the audio/video
stack log errors that are only the effect of a device leaving or arriving, and
a port that really fails logs the same lines. `HotplugTracker` (in
`bin/vekrona-error`, between `classify` and `ingest`) follows the kernel's USB
lines (`USB disconnect`, `new ... USB device number`, `New USB device found`,
the enumeration failures) and the resumes from suspend, and decides each
error-priority line from them. It reads only the entries' own
`__REALTIME_TIMESTAMP`, never the clock, so a replayed journal decides like the
live one. A kernel USB error is held for 3 s of entry time, because it can
arrive milliseconds before the disconnect that explains it.

- A line about a device that disconnected (itself or a parent) within 3 s, that
  is gone, or that connected under 60 s ago or from a suspend's entry (`PM: suspend entry`: devices resume and fail before the exit line) to 30 s after its exit
  is part of the arrival or departure and is dropped.
- A wireplumber/pipewire/udev line about a missing sound card or video device
  is dropped when a USB event happened within 15 s, or inside the 30 s after a
  suspend, as above. Anywhere else it is an ordinary error.
- A real fault makes one record per port, with source `usb`: an error on a
  device connected for more than 60 s; 3 enumeration failures within 60 s or 5
  reconnects within 120 s of a run that lasted at least 60 s (a flap that
  settles sooner is a transient); `unable to enumerate USB device` (the port is
  left disabled). The record's title, summary and count are rewritten in place
  while it goes on. A change of state
  (failing, then flapping, then dead) and a run that starts after a quiet
  minute raise the record again (status new), so the dot lights again; repeats do not.
  An unknown device counts as connected for long, so a watcher that starts in
  the middle of a fault learns the last 2 minutes of the kernel journal first.
- The context of such a record is the last 10 minutes of the kernel journal for
  the port, `lsusb -t` and `udevadm info` of the device while it is present.
