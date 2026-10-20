# Coding agents

How the coding-agent CLIs are found, kept to subscription logins, and launched.

## Installing a harness

vekrona installs no coding agent. It installs the launcher, `vekrona-agent`,
which starts whichever known harness is on `PATH` (found with `command -v`):
`claude`, `codex`, `pi`, `opencode` or `cursor-agent`. Install the ones you
want yourself, with the vendor's own installer. Claude Code, for example:

```
curl -fsSL https://claude.ai/install.sh | bash
```

This puts a self-updating `claude` in `~/.local/bin`. vekrona neither pins
nor snapshots a harness you installed: it updates itself the way its vendor
built it to. With no harness on `PATH`, `vekrona-agent` fails with a hint to
install one.

All five harnesses are meant for subscription logins, and vekrona configures
and stores no API keys. Two things enforce that. The launcher strips
API-key environment variables for every harness (see
[Agent button](#agent-button)). And stage `40-system` installs
`/etc/claude-code/managed-settings.json` with `forceLoginMethod: claudeai`,
which makes any Claude Code on the machine accept only a subscription login;
it does not switch off Claude Code's own updater. The same file is the
safety policy for Claude Code, and no project or user setting can loosen it:

- `permissions.disableBypassPermissionsMode: "disable"` refuses bypass mode
  (`--dangerously-skip-permissions`), so an injected prompt cannot run
  unchecked. The launcher likewise passes no auto-approve flag.
- `permissions.deny` keeps Claude's file tools away from secrets: `~/.ssh`,
  `~/.gnupg`, the login keyring, the vdirsyncer config (calendar URLs),
  the agent credential files, Syncthing's config, keys and generated GUI
  password, and Firefox's saved logins and cookies. The `pam_u2f` key mapping
  needs no rule: it is `/etc/u2f_mappings`, owned by root.

The deny rules are Claude Code's `Read` and `Edit` rules: they cover its own
file tools and the file commands it recognizes in a shell command (`cat`, `sed`),
not a script it writes and runs. vekrona turns on no OS sandbox, so the rules
are a speed bump for a manipulated agent, not a boundary
([threat model](threat-model.md)).

Codex, OpenCode, Pi and Cursor have no policy file, so for them only the
environment stripping protects the subscription rule, an API key stored inside
the tool itself still works, and nothing denies them the secrets above.

Earlier versions installed the harnesses through mise and a Claude Code dnf
repo. Stage `30-packages` removes what that left behind on an existing
install: mise, its repo and rpm key, the harness links in `/usr/local/bin`
(only those still pointing into mise's tree) and
`/etc/profile.d/vekrona-mise.sh`. The `/etc/mise`, `/usr/local/share/mise`,
`/etc/codex` and `/etc/opencode` directories are removed whole, with
everything in them. It leaves `nodejs24-npm` and a
`claude-code` RPM with its repo file alone; a dnf-installed Claude Code
shows up under System packages in the update flow.

## Repo signing keys

All repo files are GPG-signed (`gpgcheck=1`), and no key is fetched from the
network. The signing keys of the pinned repos are vendored in
`etc/pki/rpm-gpg/RPM-GPG-KEY-<repo>`:

| Pin (`VEKRONA_REPO_KEY_FINGERPRINTS`) | Repo | Installed by |
|---|---|---|
| `1password` | 1Password | `00-repos` |
| `rpmfusion-free-fedora-44`, `rpmfusion-nonfree-fedora-44` | RPM Fusion free and nonfree | `00-repos` |
| `protonvpn-fedora-44` | Proton VPN | `00-repos` |

Each repo file points at its copy with `gpgkey=file:///etc/pki/rpm-gpg/...`,
and `VEKRONA_REPO_KEY_FINGERPRINTS` in `lib/common.sh` pins the one
primary-key fingerprint each file must hold. `ensure_repo_key` checks the
vendored file against the pin, installs it root-owned, checks the installed
copy again, and only then runs `rpm --import`. `70-verify` re-checks the
installed files and the rpm keyring against the same pins.

COPRs and NVIDIA's CUDA repo are third-party repos anyone with an account can publish to, so they follow the same
rule: `etc/yum.repos.d/copr-<user>-<project>.repo` and `cuda-fedora<N>.repo` are vekrona's own repo files, take the key only
from the pinned vendored file (`RPM-GPG-KEY-copr-<user>-<project>`, `RPM-GPG-KEY-cuda-fedora-<N>`) and carry `includepkgs`:
a repo offers only the packages vekrona takes from it. A package that needs another one from a COPR fails to install until
that name is added to the list. `ensure_copr` (lib/common.sh) and `ensure_cuda_repo` (lib/cuda-repo.sh) install them.

RPM Fusion ships its repo files and keys inside the
`rpmfusion-{free,nonfree}-release` RPMs, whose repo files read
`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-<section>-fedora-$releasever`.
The RPM installs the per-release name as a symlink to the shared 2020 key
file. Stage `00-repos` therefore pins one key per Fedora release (the pin name is
exactly that key file's `<repo>` part, e.g. `rpmfusion-free-fedora-44`) and
does this, in order: the pinned vendored key is imported into rpm's keyring
(it is not copied into `/etc/pki/rpm-gpg`, the RPM owns that name); the release RPM
is downloaded from `mirrors.rpmfusion.org` and verified with
`assert_rpm_signed_by_pinned_key` (`rpmkeys --checksig` at verification level
`signature` against a scratch keyring holding only the pinned key, so a signature by any other key, a
missing signature (rpm's default level would accept an unsigned RPM) or a modified file dies naming the file and the key); only
then it is installed with `dnf`, from a root-owned copy of the file that was checked, not from the download directory; afterwards `assert_repo_key_trusted` proves
that the key file the RPM dropped carries exactly the pinned fingerprint and
the rpm keyring has it, and the repo files are checked to take their key
only from that file. RPM Fusion has used one key pair (the 2020 keys) since
Fedora 33, so the vendored F44 files are byte-identical to
`/usr/share/distribution-gpg-keys/rpmfusion/` for the same release.

A release without a pin cannot silently inherit trust: `ensure_repo_key`
dies with "no pinned gpg key fingerprint for repo:
rpmfusion-free-fedora-<N>" before anything is downloaded. See the
[release upgrade procedure](updates.md) for the steps.

The 1Password RPM's `%post` rewrites `/etc/yum.repos.d/1password.repo` on
every install and upgrade (with `gpgkey=` pointing at its HTTPS URL and
`repo_gpgcheck` commented out). `ensure_1password_repo_file` puts the
repo's file back right after stage `30-packages` installs the package and
right after the `dnf upgrade` in `vekrona-update`.

Proton signs each Fedora release's repo with its own key, so
`protonvpn_key_repo` names the pin after `rpm -E %fedora` (as
`rpmfusion_key_repo` does) and the vendored repo file reads
`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-protonvpn-fedora-$releasever`. The
repo's `repomd.xml` is signed by that same key, so the repo file sets
`repo_gpgcheck=1`. The `protonvpn-stable-release` RPM is not installed: it
would fetch the key over HTTPS without a pin. The key expires on 2028-03-11;
replace it, with its pin, before then. `70-verify` warns when a pinned
`*-fedora-<N>` key is not for the running Fedora release.

When a vendor rotates its signing key, the stage dies naming the expected and
the found fingerprints. Verify the new fingerprint with the vendor out of
band, then replace the vendored file and update the pin in
`VEKRONA_REPO_KEY_FINGERPRINTS` in the same commit.

## Agent button

Omarchy-style "agent button": one keystroke or bar click opens a configured
coding agent harness (Claude Code, Codex, opencode, pi, or Cursor Agent) in a
new Ghostty window, or opens the agent on a specific recorded error.

```
Hyper+a         open the coding agent (vekrona-agent --pick)
Hyper+Shift+a   toggle the robot's error list (the launcher in its /agent mode)
```

The shell's Agent widget (`config/vekrona-shell/Agent.qml`) is a bar button:
left click toggles the launcher in its `/agent` mode (the first click opens
it, the second closes it), right click does nothing. That mode lists every
recorded, non-muted error (`vekrona-error list`), newest first, with its
source, repeat count and age beside the title: Enter or a click starts the
agent on that error (`vekrona-agent --pick --error ID`) and Ctrl+Enter picks the
agent first. Typing
filters the rows and adds a row that asks the agent what was typed. The
footer names the selected row's Enter action, "Fix with agent"; Ctrl+K lists
all of the row's actions with their keys: "Fix with agent" (Enter), "Choose
agent and fix" (Ctrl+Enter) and "Mute" (`vekrona-error mute ID`, which drops
the row from the list at once and silences that error from then on).
"Launch agent" (`vekrona-agent --pick`) stays below the errors. With no
errors the list says "No recorded errors"; when `vekrona-error list` fails,
the list says so instead of showing nothing. A red dot on
the icon marks unread recorded errors
(`${XDG_STATE_HOME:-~/.local/state}/vekrona/errors/unread`, watched
event-driven via Quickshell's `FileView`) and hides when it is zero. A new
error raises the dot and nothing else: no desktop notification. Opening the
list marks the errors it shows seen, as opening the
notification centre marks every notification seen, so the dot clears; an
error that recurs after that raises it again. The ack names exactly the ids the
list read and shows (`vekrona-error ack <id>...`), so an error recorded between
the read and the ack stays unread until it is shown. When the unread count
rises, the robot's dot pulses three times (about 1.8 s) and then stays solid
(`Pulse.qml` in `config/quickshell-shared/Vekrona/`, which the shell's `Errors`
singleton feeds with the count; a shell that starts with unread errors shows the
dot solid, without a pulse).

`bin/vekrona-agent` finds each harness on `PATH` (`command -v`). A harness
that is not on `PATH` is not offered by the picker, and launching it by name
fails with a clear error (with none at all, the error tells you to install one; see
[Installing a harness](#installing-a-harness)). Every harness launches with
its own **default** permission prompts: there is no yolo/auto-approve flag
anywhere in this path (and Claude Code's bypass mode is switched off by policy).

Before launch, `vekrona-agent` strips credential variables, so every harness
authenticates through its own subscription login, never a stray key left in
the session. The list is built at launch from the user manager's environment
(`systemctl --user show-environment`), because that is the environment
`systemd-run --user` hands to the new unit. Every variable whose name matches
one of these patterns is removed: `*_API_KEY`, `*_API_TOKEN`,
`*_AUTH_TOKEN`, `*_BASE_URL`, `CLAUDE_CODE_USE_*`; plus these names:
`AWS_BEARER_TOKEN_BEDROCK`, `ANTHROPIC_PROFILE`,
`ANTHROPIC_FEDERATION_RULE_ID`, `ANTHROPIC_ORGANIZATION_ID`.
`CLAUDE_CODE_OAUTH_TOKEN` is kept on purpose: it is the Claude subscription
token, not an API key. Ambient AWS and GCP credentials are not stripped;
with `CLAUDE_CODE_USE_*` removed, Claude Code is not switched to Bedrock or
Vertex by them.

| Harness | Subscription |
|---|---|
| Claude Code (`claude`) | Claude Pro/Max, via Claude Code's own OAuth login |
| Codex (`codex`) | ChatGPT |
| opencode, pi | ChatGPT or GitHub Copilot, **not** a Claude subscription (Anthropic's terms only let a Claude subscription's OAuth token authenticate Claude Code itself, enforced since 2026-01-09) |
| Cursor Agent (`cursor-agent`) | Cursor subscription |

Run each harness once by hand first and log in; `vekrona-agent` never
automates that.

The default harness is a single id in
`${XDG_CONFIG_HOME:-~/.config}/vekrona/agent`:

```
vekrona-agent set claude         # set the default harness
vekrona-agent get                # print the default harness, nothing when none is set
vekrona-agent list                # every known harness: installed? default?
vekrona-agent choose              # always show the picker, set the default, then launch
vekrona-agent --pick              # launch the default; with no usable default, show the picker, then launch
vekrona-agent --prompt "fix the build"
vekrona-agent --pick --error 42    # launch with the recorded error's prompt (vekrona-error prompt 42), opening the picker if no usable default is set
vekrona-agent --dry-run ...        # print the final argv instead of launching, NUL-separated
```

The picker lists only the harnesses that are installed and does not accept
custom input. A default is saved only after its launch succeeded, so a failed
launch never becomes the default. A stored default that is unknown or no
longer installed is not used: `--pick` falls back to the picker, a plain
launch fails with an error. The prompt is passed after `--` for `claude`,
`codex`, `pi` and `cursor-agent`, and through `--prompt` for `opencode`.

`vekrona-agent` starts the session with `systemd-run --user --collect`
(`ghostty --class=vekrona.agent --working-directory=<this repo> -e env -u
<stripped vars...> <harness argv>`), so a keybinding or a click in the error
list never blocks, and the transient unit is dropped once it exits. `--working-directory` opens the session in the vekrona checkout, not
wherever the keybinding fired. Launcher failures go through `die` in
`lib/common.sh`, which prints to stderr and files an error record with
`vekrona-error report`, so they appear in the robot's dot and error list
instead of vanishing when no terminal is attached (a plain notification
appears only when recording the failure fails).
`--dry-run` prints the `systemd-run` argv NUL-separated, so an argument
containing a newline survives intact.
