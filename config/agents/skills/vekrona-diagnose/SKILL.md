---
name: vekrona-diagnose
description: Investigate and fix an error recorded by vekrona's error pipeline (vekrona-error). Use when asked to diagnose a vekrona error, when handed a "vekrona error <id>" prompt, or when a vekrona desktop notification's "Fix with agent" action launches an agent on one.
---

# Diagnosing a vekrona error

`vekrona-error prompt <id>` (or the notification action that launched you) gave you
a record's fields and the path to a captured `context.txt`. Read that file first,
in full: it already holds the most relevant journal excerpt (or `coredumpctl
info`/`systemctl status` output) captured at the moment the error was recorded, so
you rarely need to go hunting for the same evidence again.

## Investigate

Pull more evidence with whichever of these fits the error's `source`:

- `journalctl -u <unit> -n 200` (add `--user` for a user unit; the record's `unit`
  field tells you which) — more journal context around a failed unit than
  `context.txt` captured.
- `coredumpctl list`, `coredumpctl info <pid>`, `coredumpctl debug <pid>` — a
  coredump's backtrace; `debug` drops you into gdb if you need to go further than
  `info`'s summary.
- `systemctl status <unit>` / `systemctl --user status <unit>` — current state,
  separate from the state captured at record time.
- `dnf history` / `dnf history info <id>` — whether a recent package transaction
  is implicated.
- `snapper list` — whether a snapshot exists from before the change that likely
  caused this, and what's available to roll back to (`vekrona-rollback <N>`, but
  see "Before risky changes" below before you reach for it).

## Fix it in the repo, not on the live system

vekrona's `config/` is the source of truth; the copies under `$HOME` are symlinks
`stages/50-user.sh` creates with `ensure_symlink`. Never hand-edit a symlinked
file in `$HOME` expecting it to stick — edit the file in this repo instead, then
re-run the stage that installs it:

```
./install.sh <stage>        # e.g. ./install.sh 50-user, or ./install.sh 70 to re-verify
```

Match the repo's existing conventions while you're in there: `set -euo pipefail`,
the `log`/`warn`/`die`/`ensure_*`/`assert` helpers in `lib/common.sh`, no code
comments unless a genuine vendor quirk justifies one, no dead code, fail at the
earliest stage that can catch a problem (compile/lint/validate before runtime).
If the same fix would need repeating in more than one place, look for (or add) a
chokepoint in `lib/common.sh` instead of duplicating it.

A crash or failure that traces back to Sway, Quickshell, DMS, or the NVIDIA
driver rather than to anything in this repo is not yours to fix; note it in
`TODO.md` (with what you found, not just that it happened) instead of patching
around it here.

## Before risky changes

Take a snapshot first: `vekrona-snapshot "before <what you're about to do>"`.
Every `dnf` transaction already gets its own automatic pre/post pair, but a
snapshot right before you touch something by hand still gives you one clean
rollback point, and its description says why, which the automatic ones don't.

Don't run anything destructive, a package removal, `90b-remove`,
`vekrona-rollback`, an `rm` outside this repo, or the like, without asking first
and explaining what you found and why that's the fix.

## Out of scope

If you find a real bug or mess while investigating that isn't the error you were
sent to fix, append it to `TODO.md` in the repo root instead of fixing it as a
drive-by. Don't skip it silently either way.

## When you're done

Once you've applied a fix (or concluded there's nothing actionable and said so),
mark the error handled:

```
vekrona-error ack <id>
```
