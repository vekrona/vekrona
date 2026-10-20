# Vekrona

## Energy first, laptop first

WHEN a choice trades power draw against convenience or speed (USB or
device autosuspend, polling, timers, wakeups, always-on daemons, GPU use,
refresh rates), DO pick the lower-power option and make the convenience
recover on demand instead. Design for a laptop on battery; a desktop gets
an exception only when the low-power option breaks it.

## Apps

An app is a Firefox webapp (`config/firefox/webapps/<app>/`) unless it
needs native hardware access or a native-only capability. Then it is a
native FOSS app from Flathub, listed in `VEKRONA_FLATPAKS`
(`lib/common.sh`).

- Native: OBS (GPU and capture), Zed (GPU-rendered editor), Signal (strong
  end-to-end encryption, keys stay local).
- Native, not FOSS: Obsidian (closed source, but it has no web version and works
  on local vault files).
- Native, official Proton builds only, one sign-in per app (Proton's SSO is
  web-only): VPN from Proton's signed dnf repo
  (`etc/yum.repos.d/protonvpn-stable.repo`, tray through vekrona-shell's SNI
  tray); Mail (with Calendar), Pass and Authenticator are unsigned RPMs from
  Proton's feeds, sha512-checked into a local dnf repo by `vekrona-proton`.
- Daemon plus webapp: Syncthing (Fedora RPM user service for file access; its
  GUI at `127.0.0.1:8384` is a webapp behind a generated login, see
  `docs/threat-model.md`).
- Webapp: Telegram and Discord (proprietary and tracking, so a browser
  sandbox contains them), Spotify, SoundCloud, YouTube, WhatsApp.

Vekrona installs no coding agent; `vekrona-agent` launches the ones on `PATH`
(`docs/agents.md`).

Each webapp ships `url`, `app.desktop` and an `icon.svg` (a Simple Icons glyph on a
brand-colored square, no rounded corners), plus a `user.js` only when it needs prefs
the others do not (Spotify's DRM). Stage 50 writes each profile's `user.js` from
`config/firefox/webapp-user.js` and the app's own file, and installs the icon as
`vekrona-<app>` in the hicolor theme. `userChrome.css` is not shipped: the theme renderer
writes it into every profile. `config/firefox/policies.json` (telemetry and studies off,
no welcome pages, tracking protection on) applies to every Firefox profile.

## Bar

Every bar widget shows exactly one thing: an icon or a short text, never both.
Icon slots are equally wide (`iconS` + 2×`space2`), the tray's included. Unread
state is a dot inside that slot. A bar button's left click toggles its window,
popout or menu: the first click opens it, the second closes it, as the
notification bell does. Tray icons react to the left click only.
Exclusive keyboard surfaces (launcher, notification centre, popouts) claim the keyboard through `KeyboardSurface`.

## Verifying changes

Never verify a change on the host desktop or install test dependencies
there. Use the vekrona-dev VM (`~/wrk/vekrona-dev`, see its CLAUDE.md):
`vekrona-dev install`, `vekrona-dev session`, reproduce with real key
presses, check the screen with `vekrona-dev see`, and capture the behavior
as a `tests/e2e/` scenario that fails before the fix and passes after it.

## Upgrading Fedora to a new major release

vekrona stays on a Fedora release NVIDIA already publishes a CUDA repo for, and every third-party repo key is vendored and pinned per release
(`etc/pki/rpm-gpg/`, `VEKRONA_REPO_KEY_FINGERPRINTS` in `lib/common.sh`; verify a new key out of band first, see `docs/agents.md`). To move to
release `<N>`:

1. Check that NVIDIA publishes `cuda-fedora<N>`.
2. In `lib/cuda-repo.sh` change `CUDA_FEDORA_RELEASE` to `<N>` (it derives the repo id, the key name and the stale `cuda-fedora<N-1>.repo`
   that stage 10 and `90b-remove` drop). Rename `etc/yum.repos.d/cuda-fedora<N-1>.repo` to `cuda-fedora<N>.repo` and its `[section]`,
   `baseurl` and `gpgkey` to the new release.
3. Replace `etc/pki/rpm-gpg/RPM-GPG-KEY-cuda-fedora-<N-1>` with `RPM-GPG-KEY-cuda-fedora-<N>` and its fingerprint under the new name in
   `VEKRONA_REPO_KEY_FINGERPRINTS`.
4. Vendor `RPM-GPG-KEY-rpmfusion-free-fedora-<N>`, `RPM-GPG-KEY-rpmfusion-nonfree-fedora-<N>` and `RPM-GPG-KEY-protonvpn-fedora-<N>` the
   same way (stage 00 looks them up by `rpm -E %fedora`, so they must exist before the upgrade).
