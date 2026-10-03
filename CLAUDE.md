# Vekrona

## Apps

An app is a Firefox webapp (`config/firefox/webapps/<app>/`) unless it
needs native hardware access or a native-only capability. Then it is a
native FOSS app from Flathub, listed in `VEKRONA_FLATPAKS`
(`lib/common.sh`).

- Native: Blender, OBS (GPU and capture), Signal (strong end-to-end
  encryption, keys stay local).
- Webapp: Telegram and Discord (proprietary and tracking, so a browser
  sandbox contains them), Spotify, SoundCloud, YouTube, WhatsApp.

Each webapp ships `url`, `user.js`, `userChrome.css`, `app.desktop` and an
`icon.svg` (a Simple Icons glyph on a brand-colored rounded square). Stage 50
installs the icon as `vekrona-<app>` in the hicolor theme.

## Verifying changes

Never verify a change on the host desktop or install test dependencies
there. Use the vekrona-dev VM (`~/wrk/vekrona-dev`, see its CLAUDE.md):
`vekrona-dev install`, `vekrona-dev session`, reproduce with real key
presses, check the screen with `vekrona-dev see`, and capture the behavior
as a `tests/e2e/` scenario that fails before the fix and passes after it.
