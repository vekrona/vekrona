#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
webapps="$ROOT/config/firefox/webapps"

user_js="$scratch/user.js"
apps=()
for appdir in "$webapps"/*/; do apps+=("$(basename "$appdir")"); done

for app in "${apps[@]}"; do
  rm -f "$user_js"
  ensure_webapp_user_js "$webapps/$app" "$user_js" 2>/dev/null
  grep -qF 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' "$user_js" || die "$app: the shared prefs are missing from its user.js"
  grep -qF 'user_pref("browser.tabs.inTitlebar", 0);' "$user_js" || die "$app: the shared prefs are missing from its user.js"
done
log "ok: every webapp's user.js carries the shared prefs"

ensure_webapp_user_js "$webapps/spotify" "$user_js" 2>/dev/null
grep -qF 'media.gmp-widevinecdm.enabled' "$user_js" || die "spotify needs Widevine for its DRM"
ensure_webapp_user_js "$webapps/discord" "$user_js" 2>/dev/null
! grep -qF 'widevine' "$user_js" || die "only Spotify's profile carries the DRM prefs"
log "ok: the DRM prefs reach only Spotify"

ln -sf "$webapps/spotify/user.js" "$user_js"
ensure_webapp_user_js "$webapps/discord" "$user_js" 2>/dev/null
[[ -f "$user_js" && ! -L "$user_js" ]] || die "an earlier install's link into the checkout must become a generated file"
log "ok: a link left by an earlier install is replaced by a real file"

before="$(stat -c %i "$user_js")"
ensure_webapp_user_js "$webapps/discord" "$user_js" 2>/dev/null
[[ "$(stat -c %i "$user_js")" == "$before" ]] || die "an unchanged user.js must not be rewritten"
log "ok: an unchanged user.js is left alone"

printf '// mine\nuser_pref("a", 1);\n' >"$user_js"
if (ensure_webapp_user_js "$webapps/discord" "$user_js") 2>/dev/null; then die "a user.js that vekrona did not generate must not be overwritten"; fi
[[ "$(head -n1 "$user_js")" == '// mine' ]] || die "the foreign user.js was changed"
log "ok: a foreign user.js is refused, not overwritten"

for app in "${apps[@]}"; do
  desktop="$webapps/$app/app.desktop"
  grep -qx "Exec=vekrona-webapp $app" "$desktop" || die "$desktop: Exec must start vekrona-webapp $app"
  grep -qx "StartupWMClass=vekrona-$app" "$desktop" || die "$desktop: StartupWMClass must be vekrona-$app, the app id the window gets"
  grep -qx "Icon=vekrona-$app" "$desktop" || die "$desktop: Icon must be vekrona-$app"
  grep -qE '^Categories=(Network|AudioVideo);([A-Za-z]+;)+$' "$desktop" || die "$desktop: Categories must name a main category and a sub-category: $(grep '^Categories=' "$desktop")"
done
grep -qx 'Categories=AudioVideo;Video;' "$webapps/youtube/app.desktop" || die "YouTube plays video: it belongs in AudioVideo;Video;"
grep -qx 'Categories=Network;InstantMessaging;Chat;' "$webapps/whatsapp/app.desktop" || die "WhatsApp is a chat app, like Telegram and Discord"
log "ok: every webapp's desktop entry is consistent"

python3 -m json.tool "$ROOT/config/firefox/policies.json" >/dev/null || die "config/firefox/policies.json is not valid JSON"
policies="$(jq -c '.policies' "$ROOT/config/firefox/policies.json")"
jq -e '.DisableTelemetry == true and .DisableFirefoxStudies == true' <<<"$policies" >/dev/null || die "the policy must switch telemetry and studies (Normandy) off"
jq -e '.OverrideFirstRunPage == "" and .OverridePostUpdatePage == "" and .UserMessaging.SkipOnboarding == true' <<<"$policies" >/dev/null || die "the policy must switch the welcome pages off"
jq -e '.EnableTrackingProtection.Value == true' <<<"$policies" >/dev/null || die "the policy must switch tracking protection on"
log "ok: the Firefox enterprise policy switches telemetry and welcome pages off and tracking protection on"
