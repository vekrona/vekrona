# Error pipeline

How errors on the machine are recorded, shown and handed to a coding agent.

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
