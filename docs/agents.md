# Coding agents

How the coding-agent CLIs are installed, updated, restricted to subscription logins, and launched.

## Agents: delivery and updates

Five coding-agent CLIs run on this desktop, each launched by name from Sway
(the launcher itself is a separate concern from this repo): Claude Code,
Codex, OpenCode, Pi, and Cursor. All five are subscription-login tools; no
API keys are configured or stored by vekrona. Stage `55-agents` installs
them through exactly two package managers, so there is no per-tool lockfile
or hash management to maintain:

1. **Claude Code**, via Anthropic's own signed dnf repo
   (`etc/yum.repos.d/claude-code.repo`, package `claude-code`). This is a
   root-owned `/usr/bin/claude` that never self-updates (`claude doctor`
   reports "Auto-updates: Managed by package manager") — it only moves when
   `vekrona-update` runs `dnf upgrade`.
2. **Codex, OpenCode, Pi, and Cursor**, via one system-wide, root-owned
   [mise](https://mise.jdx.dev/) install (`etc/yum.repos.d/mise.repo`,
   package `mise`, plus `nodejs24-npm` for mise's npm backend). `/etc/mise/config.toml`
   pins the tool list and sets a supply-chain cooldown,
   `minimum_release_age = "1d"`: mise will not install or upgrade to a
   release less than a day old, so a same-day compromised release of any of
   these tools is never pulled automatically. The cooldown is verified to
   apply to the npm backend (Codex, Pi) and the aqua backend (OpenCode). It
   does **not** apply to Cursor: `cursor-agent` comes from mise's http
   backend, which only ever exposes the current build, so there is no older
   build for the cooldown to fall back to. Separately, OpenCode's aqua entry
   and Cursor's http entry carry no upstream checksum in `mise`'s registry,
   so integrity for those two rests on HTTPS transport alone, not a pinned
   hash. Both are residual, accepted risks; see [TODO.md](../TODO.md).

`nodejs24-npm` rather than Fedora's older Node stream because mise can only
apply the cooldown to npm's transitive dependencies through npm's own
`min-release-age`, which needs npm 11.10 or newer. The stage runs
`assert_npm_supports_release_age` right after installing the package and
dies on an older npm. With mise's default `npm.package_manager = auto`, mise
installs npm-backed tools with its embedded package manager, applies the
cutoff itself and passes `--ignore-scripts=true`; this was observed locally
on one install and is still to be confirmed in the VM. When mise cannot
apply the cooldown it prints `minimum_release_age is set for ...`;
`mise_system_strict` turns that warning into a fatal error for both
`55-agents` and `vekrona-update`, so the cooldown never silently covers less
than it claims.

All repo files are GPG-signed (`gpgcheck=1`), and no key is fetched from the
network. The signing keys of the three vendor repos (Claude Code, mise,
1Password) are vendored in `etc/pki/rpm-gpg/RPM-GPG-KEY-<repo>`. Each repo
file points at its copy with `gpgkey=file:///etc/pki/rpm-gpg/...`, and
`VEKRONA_REPO_KEY_FINGERPRINTS` in `lib/common.sh` pins the one primary-key
fingerprint each file must hold. `ensure_repo_key` (stage `00-repos` for
1Password, `55-agents` for the other two) checks the vendored file against
the pin, installs it root-owned, checks the installed copy again, and only
then runs `rpm --import`. `70-verify` re-checks the installed files and the
rpm keyring against the same pins.

The 1Password RPM's `%post` rewrites `/etc/yum.repos.d/1password.repo` on
every install and upgrade (with `gpgkey=` pointing at its HTTPS URL and
`repo_gpgcheck` commented out). `ensure_1password_repo_file` puts the
repo's file back right after stage `30-packages` installs the package and
right after the `dnf upgrade` in `vekrona-update`.

When a vendor rotates its signing key, the stage dies naming the expected and
the found fingerprints. Verify the new fingerprint with the vendor out of
band, then replace the vendored file and update the pin in
`VEKRONA_REPO_KEY_FINGERPRINTS` in the same commit.

`mise install --system`/`mise upgrade --system` only work for
binary-download backends, which rules out Codex and Pi (npm backend); the
one form that installs, upgrades, and reshims all four tools uniformly is to
skip `--system` and instead point plain `mise` at root-owned directories:
`MISE_DATA_DIR=/usr/local/share/mise MISE_CONFIG_DIR=/etc/mise`. This is the
`mise_system` helper in `lib/common.sh`, the one chokepoint stage
`55-agents` and `bin/vekrona-update` both call, so there is exactly one place
that knows how mise is invoked system-wide. `mise_system` runs this through
`sudo`, which resets `HOME` to `/root`; left alone, that would leak npm's and
mise's own caches into `/root` on every install or upgrade. `mise_system`
pins `HOME`, `MISE_CACHE_DIR`, `MISE_STATE_DIR`, and `npm_config_cache` to
paths under `/usr/local/share/mise` instead, so nothing lands outside the
managed tree; verified empirically by diffing a full listing of `/root`
before and after a real (network-downloading) `mise_system install` — zero
new entries. The result, `/usr/local/share/mise/installs/*` and
`/usr/local/share/mise/shims/{codex,pi,opencode,cursor-agent}`, is
root:root and not writable by the user; stage `55-agents` asserts this by
actually attempting a write and expecting it to fail, not by only reading
permission bits.

PATH carries the shims directory,
`/usr/local/share/mise/shims`, in two places, since the sway session and a
login shell/SSH/TTY session build their `PATH` differently: the sway session
picks it up from `config/environment.d/vekrona.conf` (placed before
`~/.local/bin` and the rest of the existing `PATH`), and a login shell, SSH session, or plain text console
picks it up from `etc/profile.d/vekrona-mise.sh` (a root file,
`ensure_root_file`; it appends the directory only when it is not already on
`PATH`, so nested login shells do not add it twice).
In a login shell the shims directory is last, so a user-level copy can win a
plain `PATH` lookup. The launcher does not rely on `PATH`: it runs each
harness by its absolute managed path (`managed_binary` in `lib/common.sh`:
`/usr/bin/claude`, or the mise shim), and `vekrona-agent` warns when another
copy of the same name (for example a native Claude Code installer's
`~/.local/bin/claude`) shadows it on `PATH`. `70-verify` also warns about such
copies. They can self-update outside the snapshotted root; remove them.

### Subscription-only enforcement per tool

`vekrona-agent` strips API-key variables from the environment (see [Agent button](#agent-button)), but a tool can also be told directly. Stage `55-agents` installs
four root-owned policy files for that, and `70-verify` asserts that each is
installed, root-owned, not group/other-writable and identical to the repo
copy:

| Tool | Login method | Self-update |
|---|---|---|
| Claude Code | `forceLoginMethod: claudeai` in `/etc/claude-code/managed-settings.json` | disabled there (`DISABLE_AUTOUPDATER`, `DISABLE_UPDATES`) |
| Codex | `allowed_login_methods = ["chatgpt"]` in `/etc/codex/requirements.toml` | update check off in `/etc/codex/managed_config.toml` |
| OpenCode | no setting to enforce it | `autoupdate: false` in `/etc/opencode/opencode.json` |
| Pi | no setting to enforce it | version check disabled by `PI_SKIP_VERSION_CHECK=1`, which only `vekrona-agent` sets |
| Cursor | not documented | not documented |

For OpenCode, Pi and Cursor only the environment stripping protects the
subscription-only rule, so an API key the user stores inside the tool itself
still works. OpenCode's `OPENCODE_DISABLE_AUTOUPDATE` variable is not set
anywhere: OpenCode does not document it, and `autoupdate: false` is the
documented mechanism. Whether each tool honours its policy file is only
proven by running it in the VM; the checks in `vm/agents-check.sh` cover that
the files and their keys are in place.

## Agent button

Omarchy-style "agent button": one keystroke or bar click opens a configured
coding agent harness (Claude Code, Codex, opencode, pi, or Cursor Agent) in a
new Ghostty window, or opens the agent on a specific recorded error.

```
Hyper+a         open the coding agent (vekrona-agent --pick)
Hyper+Shift+a   pick a recorded error and open the agent on it (vekrona-error pick)
```

The DankBar plugin `config/DankMaterialShell/plugins/vekronaAgent/` shows the
same two actions as a bar button: left click runs `vekrona-agent --pick`,
right click runs `vekrona-error pick`. A small badge on the icon shows the
unread recorded-error count
(`${XDG_STATE_HOME:-~/.local/state}/vekrona/errors/unread`, watched
event-driven via Quickshell's `FileView`) and hides when it is zero. Stage
`50-user` symlinks the plugin directory in with the rest of
`config/DankMaterialShell/plugins/`, enables it in `plugin_settings.json`,
and inserts `vekronaAgent` into a bar's widget list (before
`notificationButton`) if it is not already present, the same idempotent
pattern used for `vekronaSwayWorkspaces`; `settings.seed.json` already ships
it in place for a fresh install.

`bin/vekrona-agent` runs every harness by its absolute managed path
(`managed_binary` in `lib/common.sh`), never by `PATH` lookup: `claude` is the
RPM's `/usr/bin/claude`, the rest are mise shims. A harness that is not
installed fails with a clear error telling you to run `./install.sh
55-agents` or `vekrona-update`. Every harness launches with its own
**default** permission prompts: there is no yolo/auto-approve flag anywhere
in this path. The launcher is the only place that warns about a shadowing
copy on `PATH`.

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
vekrona-agent get                # print the default harness
vekrona-agent list                # every known harness: installed? default?
vekrona-agent choose              # always show the picker, set the default, then launch
vekrona-agent                     # launch the default harness (fails with no usable default)
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
<stripped vars...> <harness argv>`), so a keybinding, bar click or
notification action never blocks, and the transient unit is dropped once it
exits. `--working-directory` opens the session in the vekrona checkout, not
wherever the keybinding fired. Launcher failures go through `die` in
`lib/common.sh`, which prints to stderr and files an error record with
`vekrona-error report`, so they appear in the error pipeline and the
desktop notification instead of vanishing when no terminal is attached.
`--dry-run` prints the `systemd-run` argv NUL-separated, so an argument
containing a newline survives intact.
