#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
MARKER="$VEKRONA_STATE_DIR/offline-pending"
JSON="$VEKRONA_STATE_DIR/updates.json"

post() { run_as_root "$REPO/libexec/vekrona-update-post" 2>"$work/err"; }
reset() {
  date -Iseconds >"$MARKER"
  echo '{"pending": true}' >"$JSON"
  echo "No offline transaction is stored." >"$work/offline.status"
  rm -f "$work"/sessions/* "$work/notify.fails"
  sed 's/^repo_gpgcheck=1/repo_gpgcheck=0/' "$REPO/etc/yum.repos.d/1password.repo" >"$work/repos/1password.repo"
  : >"$FAKE_LOG"
}

reset; add_session 1
post
[[ "$(jq .pending "$JSON")" == false ]] || die "updates.json still says pending after the update: $(cat "$JSON")"
cmp -s "$work/repos/1password.repo" "$REPO/etc/yum.repos.d/1password.repo" || die "the 1Password repo file was not repaired"
grep -q 'runuser -u someone -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus notify-send -a vekrona .*System updated' "$FAKE_LOG" \
  || die "the user was not told: $(cat "$FAKE_LOG")"
[[ ! -e "$MARKER" ]] || die "the marker survived"
log "ok: a finished offline update repairs the repo file, rewrites updates.json, tells the user and removes the marker"

reset
post
grep -q '^runuser' "$FAKE_LOG" && die "notified with nobody logged in"
[[ ! -e "$MARKER" ]] || die "the marker survived"
log "ok: with nobody logged in the update still finishes"

reset; add_session 1; touch "$work/notify.fails"
if post; then die "a failing notification was ignored"; fi
[[ ! -e "$MARKER" ]] || die "the marker survived a failed notification"
log "ok: a notification that fails is an error"

for status in "An offline transaction was started, but it did not finish. Run \`dnf5 offline log\` for more information." \
  "An offline transaction was initiated by the following command: dnf5 upgrade --offline"; do
  reset; add_session 1
  echo "$status" >"$work/offline.status"
  if post; then die "a transaction still stored was taken as finished: $status"; fi
  grep -q "did not finish: $status" "$work/err" || die "the status is not in the error: $(cat "$work/err")"
  grep -q 'offline log line' "$work/err" || die "the dnf log is not in the error: $(cat "$work/err")"
  [[ ! -e "$MARKER" ]] || die "the marker survived a failed update"
  [[ "$(jq .pending "$JSON")" == false ]] || die "updates.json was not refreshed after a failed update"
  grep -q 'notify-send' "$FAKE_LOG" && die "reported a failed update as updated"
done
log "ok: a transaction dnf still holds fails the unit with dnf's status and log, and updates.json is refreshed"

reset; rm "$MARKER"
if post; then die "ran without the marker"; fi
grep -q 'no offline update is pending' "$work/err" || die "no marker error: $(cat "$work/err")"
log "ok: without the marker there is nothing to report"
