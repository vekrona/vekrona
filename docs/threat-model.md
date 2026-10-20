# Threat model

What vekrona protects, from whom, and where it deliberately does not. It is one laptop or
desktop with one user. The user is trusted; the things that run as the user are not all.

## What is not defended

A process that runs as you can do what you can do. vekrona runs Steam games, Firefox,
Flatpaks, coding agents and shell scripts as one Unix user, with no sandbox between them,
except where a row below says so. So malware that already runs as you can read your files,
use your Wayland session and take what an unlocked keyring hands out. The boundaries below
keep that malware out, or keep less valuable things from becoming such a process.

## Trust boundaries

| Boundary | Who is on the far side | What holds it |
|---|---|---|
| Local processes and the loopback network | Other users' processes, sandboxed apps that share the network, any program that can open `127.0.0.1` | The Syncthing GUI and REST API (`127.0.0.1:8384`) sit behind a login that stage 50 generates (user `vekrona`, password in `~/.local/state/vekrona/syncthing-gui-password`, mode 0600). Without it every local process could reconfigure the daemon. sshd takes keys only and listens on the tailnet only (stage 40, firewalld zone `tailnet`). |
| Journal to coding-agent prompt | Whoever can get a line into a log: a web page through a webapp, a file name, a peer on the network | `vekrona-error` copies journal text into `context.txt` and the prompt it hands the agent. The `vekrona-diagnose` skill says all of it is data, never instructions. Agents run with their default permission prompts: the launcher passes no auto-approve flag, and the managed policy switches Claude Code's bypass mode off. Read each prompt before you approve it. |
| Coding agent to your secrets | A manipulated or mistaken agent | `/etc/claude-code/managed-settings.json` denies Claude Code's file tools `~/.ssh`, `~/.gnupg`, the login keyring, the calendar config, agent credentials, Syncthing's keys and password, and Firefox logins and cookies ([agents](agents.md#installing-a-harness)). This covers its file tools and the file commands it recognizes in a shell command, not a script it writes and runs, and there is no OS sandbox: it slows a manipulated agent down, it does not box it in. Codex, OpenCode, Pi and Cursor have no such policy. |
| Webapps | The sites behind Telegram, Discord, Spotify, SoundCloud, YouTube, WhatsApp | Each runs in its own Firefox profile (`vekrona-<app>`), so cookies and logins are not shared with your browser or with each other, and Firefox's content sandbox contains the page. One enterprise policy (`config/firefox/policies.json`) turns telemetry and studies off, skips the welcome pages and turns tracking protection on for every profile. A webapp is not a VM: a Firefox exploit runs as you. |
| Lock screen and security key | Someone at your machine | The lock (`vekrona-lock`) takes your security key with its PIN and a touch (`pinverification=1`, as sudo, polkit and the login greeter do), your password or your fingerprint. The key alone, without its PIN, unlocks nothing. The launcher's Sleep, the sleep key and a closed lid lock first (`vekrona-suspend`; `vekrona-lid.service` keeps logind from handling the lid and the sleep key itself while the session runs). A screen that cannot be locked holds a block lock on sleep (`vekrona-lock-guard.service`), so the machine stays awake with the session open and a record in the error list instead of suspending unlocked. The remaining gap is a suspend that something asks logind for directly, such as `systemctl suspend` in a terminal: swayidle's before-sleep hook tries to lock, but logind cannot cancel a suspend that has begun. Idle locks after 5 minutes. |
| Root | Any process running as you that wants root | sudo and polkit need the key's PIN and a touch, or the password. Every pam_u2f line reads the registration file `/etc/u2f_mappings`, owned by root with mode 0644, which a process of yours cannot rewrite: it cannot register a key of its own and sign in as you. (The old `~/.config/Yubico/u2f_keys` is never read again; `./install.sh 45` moves your line out of it once.) sudo has a PAM service of its own, `etc/pam.d/vekrona-sudo`, the stock one plus `XDG_SESSION_CLASS=none` so that `pam_systemd` opens no logind session for each sudo (a logind bug piles up closing sessions); authentication is unchanged (`etc/sudoers.d/50-vekrona-sudo-pam-service`). |
| Supply chain | Whoever can alter a package or download | Every dnf repo is GPG-checked against a vendored key whose fingerprint is pinned in `lib/common.sh` ([repo signing keys](agents.md#repo-signing-keys)). Each COPR repo and NVIDIA's CUDA repo also lists the packages it may provide (`includepkgs` in its repo file under `etc/yum.repos.d/`), so a compromised or expanded repo cannot replace a system package such as the kernel, glibc or the NVIDIA driver; RPM Fusion's driver comes from RPM Fusion alone. Downloads use `https` only, also after a redirect (`download_file`). Proton's unsigned RPMs are sha512-checked against their feed into a local repo. ScopeBuddy is fetched at a tag and checked against a pinned sha256. devbox comes from a pinned nixpkgs commit. Flathub apps are Flatpaks signed by Flathub. Claude Code and the other agents you install yourself update themselves outside the snapshotted root, and nothing pins them. |
| LAN | Other machines on the same network (a cafe, a hotel) | firewalld's default zone is `public`, which opens only the services listed in `lib/firewall.sh` (mDNS, DHCPv6, Syncthing, Steam streaming and Steam LAN transfer) and AirPlay's UDP ports. Fedora's workstation zone, which opens every port from 1025, is not used. Stage 40 sets it and stage 70 checks it. |
| Disk | Someone with the powered-off machine | LUKS root, unlocked by password or by a FIDO2 key with PIN and touch ([sign-in](sign-in.md)). |

## The `input` group

Your user is not in the `input` group. `xremap-wlroots` runs as a system service under its own user, `xremap`
(`etc/systemd/system/xremap.service`), and that user alone reads the keyboards. So a process running as you cannot log the key
presses on the machine, including the password typed on the lock screen, and cannot inject key events: the udev rule
`etc/udev/rules.d/70-vekrona-uinput.rules` takes the seat's access to `/dev/uinput` away, so only `input` (that is, xremap) may open it.
xremap's config is root's copy, `/etc/xremap/config.yml`, because a config you could write would run commands as the xremap user.

What this costs: a program that needs raw input devices (an input remapper, a game controller tool that opens `/dev/input/event*`) now
needs `sudo` or an ACL you grant on purpose.

## When you change something here

A new listener on a local port, a new place that copies untrusted text into an agent prompt, a new
secret file, or a new way to reach root belongs in the table above in the same commit.
