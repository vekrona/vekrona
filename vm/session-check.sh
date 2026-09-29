#!/usr/bin/env bash
set -euo pipefail

fail() { echo "session-check FAILED: $*" >&2; exit 1; }

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

cleanup() { systemctl --user stop vekrona-sway-test.service >/dev/null 2>&1 || true; }
trap cleanup EXIT

systemctl --user reset-failed vekrona-sway-test.service >/dev/null 2>&1 || true
systemd-run --user --unit vekrona-sway-test \
  --setenv=WLR_BACKENDS=headless --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
  -- sway -c "$HOME/.config/sway/config" --unsupported-gpu \
  || fail "could not start sway via systemd-run"

sockfile=""
attempt=0
until [[ -n "$sockfile" ]]; do
  for sock in "$XDG_RUNTIME_DIR"/sway-ipc.*; do
    [[ -e "$sock" ]] && { sockfile="$sock"; break; }
  done
  [[ -n "$sockfile" ]] && break
  attempt=$((attempt + 1))
  [[ $attempt -lt 60 ]] || fail "sway ipc socket never appeared"
  sleep 1
done
export SWAYSOCK="$sockfile"

swaymsg -t get_version >/dev/null || fail "swaymsg get_version failed"

[[ "$(systemctl --user is-active sway-session.target 2>/dev/null || true)" == active ]] \
  || fail "sway-session.target not active"

dms_active=""
attempt=0
until [[ "$dms_active" == active ]]; do
  dms_active="$(systemctl --user is-active dms.service 2>/dev/null || true)"
  [[ "$dms_active" == active ]] && break
  attempt=$((attempt + 1))
  [[ $attempt -lt 30 ]] || fail "dms.service did not become active"
  sleep 2
done

dms ipc call lock status >/dev/null || fail "dms ipc call lock status failed"

xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml" || fail "xremap config failed to validate"

swaymsg exit >/dev/null 2>&1 || true

echo "session-check OK"
