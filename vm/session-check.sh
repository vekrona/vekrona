#!/usr/bin/env bash
set -euo pipefail

fail() { echo "session-check FAILED: $*" >&2; exit 1; }

command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

cleanup() {
  if [[ -n "${SWAY_WATCH_PID:-}" ]]; then
    kill "$SWAY_WATCH_PID" >/dev/null 2>&1 || true
  fi
  systemctl --user stop vekrona-sway-test.service >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_line() {
  local fd="$1" want="$2" line
  while IFS= read -r -u "$fd" line; do
    [[ "$line" == "$want" ]] && return 0
  done
  return 1
}

wait_until() {
  local timeout="$1" deadline; shift
  deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    inotifywait -qq -t 1 -e create,modify,moved_to "$XDG_RUNTIME_DIR" >/dev/null 2>&1 || true
  done
}

systemctl --user reset-failed vekrona-sway-test.service >/dev/null 2>&1 || true

pgrep -x sway >/dev/null && fail "a sway process is already running"
find "$XDG_RUNTIME_DIR" -maxdepth 1 -regextype posix-extended \
  -regex '.*/sway-ipc\.[0-9]+\.[0-9]+\.sock' -delete

coproc SWAY_WATCH {
  inotifywait -e create --include 'sway-ipc\.[0-9]+\.[0-9]+\.sock$' \
    --format '%f' -t 60 "$XDG_RUNTIME_DIR" 2>&1
}
wait_for_line "${SWAY_WATCH[0]}" "Watches established." \
  || fail "could not set up the sway ipc socket watch"

systemd-run --user --unit vekrona-sway-test \
  --setenv=WLR_BACKENDS=headless --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
  -- sway -c "$HOME/.config/sway/config" --unsupported-gpu \
  || fail "could not start sway via systemd-run"

IFS= read -r -u "${SWAY_WATCH[0]}" sockname || fail "sway ipc socket never appeared"
sockfile="$XDG_RUNTIME_DIR/$sockname"
[[ -S "$sockfile" ]] || fail "sway ipc socket not found: $sockfile"
export SWAYSOCK="$sockfile"

swaymsg -t get_version >/dev/null || fail "swaymsg get_version failed"

systemctl --user start sway-session.target || fail "sway-session.target did not become active"
[[ "$(systemctl --user is-active sway-session.target 2>/dev/null || true)" == active ]] \
  || fail "sway-session.target not active"

systemctl --user start dms.service || fail "dms.service did not become active"

wait_until 30 dms ipc call lock status || fail "dms ipc call lock status failed"

xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml" || fail "xremap config failed to validate"

swaymsg exit >/dev/null 2>&1 || true

echo "session-check OK"
