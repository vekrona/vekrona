#!/usr/bin/env bash
# The Syncthing GUI and REST API listen on 127.0.0.1:8384, which every process of the machine reaches. Stage 50 gives them a login.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=90
STATUS_URL=http://127.0.0.1:8384/rest/system/status

# The REST API answers 403 "CSRF Error" to a request without the token the GUI page hands out, login or not, so an anonymous request
# carries the token: it is then refused only by the login.
anonymous_status() {
  vekrona-dev run bash -c '
jar="$(mktemp)"
curl -s -o /dev/null -c "$jar" http://127.0.0.1:8384/
name="$(awk "/CSRF-Token/ { print \$6 }" "$jar")"
token="$(awk "/CSRF-Token/ { print \$7 }" "$jar")"
curl -s -o /dev/null -w "%{http_code}" -b "$jar" -H "X-$name: $token" "$1"
rm -f "$jar"' _ "$STATUS_URL"
}
gui_answers() { [[ "$(anonymous_status)" =~ ^(200|401|403)$ ]]; }
export -f anonymous_status gui_answers
export STATUS_URL

vekrona-dev session
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- gui_answers

anonymous="$(anonymous_status)"
[[ "$anonymous" == 401 || "$anonymous" == 403 ]] || die "an anonymous request to the Syncthing REST API got HTTP $anonymous, not a refusal"
log "ok: the Syncthing REST API refuses anonymous requests"

# The GUI's login form posts the credentials here and gets a session cookie (204); the REST calls themselves want that cookie or the API key.
LOGIN_URL=http://127.0.0.1:8384/rest/noauth/auth/password
login_status() {
  vekrona-dev run bash -c 'printf "{\"username\":\"vekrona\",\"password\":\"%s\"}" "$2" | curl -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" --data @- "$1"' _ "$LOGIN_URL" "$1"
}

signed_in="$(login_status "$(vekrona-dev run bash -c 'cat "$HOME/.local/state/vekrona/syncthing-gui-password"')")"
[[ "$signed_in" == 204 ]] || die "the stored password is refused by Syncthing: HTTP $signed_in"
log "ok: the stored password signs in"

refused="$(login_status wrong-password)"
[[ "$refused" == 403 ]] || die "a wrong password got HTTP $refused, not a refusal"
log "ok: a wrong password does not"
