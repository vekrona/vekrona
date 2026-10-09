#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"

notifications() { grep -c 'notify-send' "$FAKE_LOG" || true; }

add_session 1 Name=ann User=1001
add_session 2 Name=bob User=1002 Active=no
add_session 3 Name=cid User=1003 Type=tty
add_session 4 Name=dee User=1004 IdleHint=yes
notify_user -u critical "Title" "Body" 2>/dev/null
grep -qx 'runuser -u ann -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus notify-send -a vekrona -u critical Title Body' "$FAKE_LOG" \
  || die "ann was not notified on her own bus: $(cat "$FAKE_LOG")"
grep -qx 'runuser -u dee -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1004/bus notify-send -a vekrona -u critical Title Body' "$FAKE_LOG" \
  || die "an idle user's session is still a session to notify: $(cat "$FAKE_LOG")"
[[ "$(notifications)" -eq 2 ]] || die "notified users without an active Wayland session: $(cat "$FAKE_LOG")"
log "ok: every active Wayland session's user is notified on that user's bus, nobody else"

[[ "$(wayland_sessions awake)" == "1001 ann" ]] || die "awake sessions: $(wayland_sessions awake)"
log "ok: awake leaves out idle sessions"

rm "$work"/sessions/*; : >"$FAKE_LOG"
if notify_user "Title" 2>"$work/err"; then die "notify_user succeeded with nobody to tell"; fi
grep -q 'no graphical session to notify' "$work/err" || die "no explanation: $(cat "$work/err")"
[[ "$(notifications)" -eq 0 ]] || die "notified with no session"
log "ok: with no graphical session it logs and returns non-zero for the caller to decide"

add_session 1; touch "$work/notify.fails"
if (notify_user "Title") 2>"$work/err"; then die "a failing notify-send was ignored"; fi
grep -q 'notify-send failed for someone' "$work/err" || die "no failure message: $(cat "$work/err")"
log "ok: a failing notify-send is an error"

rm "$work/notify.fails"; echo install >"$work/answer"
[[ "$(ask_user 1000 someone --timeout 5 --title T)" == install ]] || die "ask_user did not return the answer"
grep -qx 'runuser -u someone -- env DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus /usr/local/lib/vekrona/bin/vekrona-update-ask --timeout 5 --title T' "$FAKE_LOG" \
  || die "vekrona-update-ask was not run as the user from the root-owned copy: $(cat "$FAKE_LOG")"
log "ok: ask_user runs the root-owned vekrona-update-ask as the user and prints its answer"
