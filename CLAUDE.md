# Vekrona

## Apps

An app is a Firefox webapp (`config/firefox/webapps/<app>/`) unless it
needs native hardware access or a native-only capability. Then it is a
native FOSS app from Flathub, listed in `VEKRONA_FLATPAKS`
(`lib/common.sh`).

- Native: Blender, OBS (GPU and capture), Signal (strong end-to-end
  encryption, keys stay local).
- Native, not FOSS: Obsidian (closed source, but it has no web version and works
  on local vault files).
- Native, official Proton builds only, one sign-in per app (Proton's SSO is
  web-only): VPN from Proton's signed dnf repo
  (`etc/yum.repos.d/protonvpn-stable.repo`, tray through vekrona-shell's SNI
  tray); Mail (with Calendar), Pass and Authenticator are unsigned RPMs from
  Proton's feeds, sha512-checked into a local dnf repo by `vekrona-proton`.
- Daemon plus webapp: Syncthing (Fedora RPM user service for file access; its
  GUI at `127.0.0.1:8384` is a webapp).
- Webapp: Telegram and Discord (proprietary and tracking, so a browser
  sandbox contains them), Spotify, SoundCloud, YouTube, WhatsApp.

Each webapp ships `url`, `user.js`, `userChrome.css`, `app.desktop` and an
`icon.svg` (a Simple Icons glyph on a brand-colored square, no rounded corners). Stage 50
installs the icon as `vekrona-<app>` in the hicolor theme.

## Verifying changes

Never verify a change on the host desktop or install test dependencies
there. Use the vekrona-dev VM (`~/wrk/vekrona-dev`, see its CLAUDE.md):
`vekrona-dev install`, `vekrona-dev session`, reproduce with real key
presses, check the screen with `vekrona-dev see`, and capture the behavior
as a `tests/e2e/` scenario that fails before the fix and passes after it.

## Upgrading Fedora to a new major release

`stages/10-nvidia.sh`, `stages/70-verify.sh` and `stages/90b-remove.sh` hardcode the CUDA repo release (`fedora44` current, `fedora43` stale) on purpose: vekrona stays on a release NVIDIA already publishes. When moving to the next Fedora release, first check that NVIDIA publishes `cuda-fedora<N>`, then replace `fedora44` with `fedora<N>` and `fedora43` with `fedora<N-1>` wherever they appear (`CUDA_REPO_ID`, `CUDA_REPOFILE_URL` and `OLD_CUDA_REPOFILE` in stage 10, the two repo checks in 70, the stale repo file in 90b).
