#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"

# The check and the apply step are replaced: the check writes the verdict the test sets, the apply step only records
# that it ran.
cat >"$work/check" <<'F'
#!/usr/bin/env bash
echo "check" >>"$FAKE_LOG"
[[ ! -e "$FAKE_WORLD/check.fails" ]] || exit 1
if [[ -e "$FAKE_WORLD/pending" ]]; then
  echo '{"pending": true, "groups": [{"name": "System packages", "items": [{}, {}]}, {"name": "Flatpak", "items": [{}]}]}'
else
  echo '{"pending": false, "groups": []}'
fi >"$VEKRONA_STATE_DIR/updates.json"
F
cat >"$work/apply" <<'F'
#!/usr/bin/env bash
echo "apply $*" >>"$FAKE_LOG"
F
chmod +x "$work/check" "$work/apply"
export VEKRONA_UPDATE_CHECK="$work/check" VEKRONA_UPDATE_APPLY="$work/apply"

# scenario NAME: a clean machine with nothing pending and nobody logged in.
scenario() {
  rm -f "$work"/sessions/* "$work/pending" "$work/check.fails"
  : >"$work/inhibitors"
  echo timeout >"$work/answer"
  : >"$FAKE_LOG"
  unset VEKRONA_UPDATE_ASK_TIMEOUT
}
night() { run_as_root "$REPO/libexec/vekrona-update-night" 2>"$work/err"; }
night_fails() { if night; then die "$1"; fi; }
ran() { grep -q -- "$1" "$FAKE_LOG"; }
did_not() { ! ran "$1"; }

scenario
night
ran '^systemctl suspend$' || die "nothing pending and nobody there did not suspend"
did_not '^apply' || die "nothing pending still installed"
log "ok: nothing to install and nobody at the machine suspends it"

scenario; add_session 1
night
did_not '^systemctl suspend$' || die "suspended under somebody who is working"
did_not '^runuser' || die "asked about updates when there are none"
did_not '^apply' || die "nothing pending still installed"
log "ok: nothing to install and somebody at the machine leaves it on"

scenario; add_session 1 LockedHint=yes
night
ran '^systemctl suspend$' || die "a locked session counted as somebody at the machine"
log "ok: a locked session is nobody at the machine"

for answer in timeout skip closed; do
  scenario; touch "$work/pending"; add_session 1; echo "$answer" >"$work/answer"
  night
  ran '^runuser' || die "an awake user was not asked"
  did_not '^apply' || die "installed after the answer '$answer'"
  did_not '^systemctl suspend$' || die "suspended itself after '$answer', that is logind's job"
done
log "ok: timeout, skip and a closed notification skip the night"

scenario; touch "$work/pending"; add_session 1; echo install >"$work/answer"
night
ran '^apply --offline$' || die "the answer 'install' did not start the offline install"
ran 'vekrona-update-ask --timeout 600 --title .* --body System packages 2, Flatpak 1 --action skip=Skip tonight --action install=Install and reboot' \
  || die "the question lacks its default timeout, summary or buttons, or the harmless skip is not first (a click on the toast body runs the first): $(grep runuser "$FAKE_LOG")"
log "ok: install installs offline; the question carries the summary and a 600 s default timeout"

scenario; touch "$work/pending"; add_session 1; echo install >"$work/answer"
VEKRONA_UPDATE_ASK_TIMEOUT=2 night
ran 'vekrona-update-ask --timeout 2 ' || die "VEKRONA_UPDATE_ASK_TIMEOUT was ignored"
log "ok: the question's timeout follows VEKRONA_UPDATE_ASK_TIMEOUT"

scenario; touch "$work/pending"; add_session 1; echo maybe >"$work/answer"
night_fails "an unknown answer was taken as consent"
did_not '^apply' || die "installed after an unknown answer"
grep -q "unexpected answer: 'maybe'" "$work/err" || die "an unknown answer was not reported: $(cat "$work/err")"
log "ok: an answer that is not install, skip, timeout or closed is an error"

scenario; touch "$work/pending"; VEKRONA_UPDATE_ASK_TIMEOUT=soon night_fails "a non-numeric timeout was accepted"
grep -q "VEKRONA_UPDATE_ASK_TIMEOUT" "$work/err" || die "a bad timeout was not reported: $(cat "$work/err")"
log "ok: a timeout that is not a number of seconds is an error"

scenario; touch "$work/pending"
night
ran '^apply --offline$' || die "nobody at the machine did not install"
did_not '^runuser' || die "asked when nobody is there"
log "ok: pending updates with nobody there install without asking"

for state in LockedHint=yes IdleHint=yes; do
  scenario; touch "$work/pending"; add_session 1 "$state"
  night
  ran '^apply --offline$' || die "a session with $state did not install"
  did_not '^runuser' || die "asked a session with $state"
done
log "ok: a locked or idle session is not asked"

scenario; touch "$work/pending"; add_session 1 Active=no
night
ran '^apply --offline$' && did_not '^runuser' || die "a background session was asked or blocked the install"
scenario; touch "$work/pending"; add_session 1 Type=tty
night
ran '^apply --offline$' && did_not '^runuser' || die "a console session was asked"
log "ok: only the active Wayland session counts as somebody at the machine"

scenario; touch "$work/pending"
echo "Updater 1000 someone 4242 updater shutdown Installing something important block" >"$work/inhibitors"
night_fails "installed while a block inhibitor holds the shutdown"
did_not '^apply' || die "applied over a block inhibitor"
grep -q "Updater 1000 someone 4242 updater shutdown Installing something important block" "$work/err" \
  || die "the holder is not named: $(cat "$work/err")"
log "ok: a block inhibitor on shutdown stops the install and names the holder"

scenario; touch "$work/pending"
cat >"$work/inhibitors" <<'F'
swayidle       1000 someone 273226  swayidle sleep    Swayidle is preventing sleep delay
Backup         1000 someone 4243    backup   shutdown Copying                      delay
Player         1000 someone 4244    player   sleep    Playing                      block
Ticker         1000 someone 4245    ticker   shutdown Ticking                      block-weak
F
night
ran '^apply --offline$' || die "delay, weak and non-shutdown inhibitors blocked the install"
log "ok: only a block inhibitor on shutdown blocks the install"

scenario; touch "$work/pending"; touch "$work/check.fails"
night_fails "a failed re-check was ignored"
did_not '^apply' || die "installed after a failed re-check"
log "ok: a failed re-check fails the run"

scenario
night
[[ "$(log_lines '^check$')" -eq 1 ]] || die "the night run did not check first"
log "ok: the night run re-checks first"
