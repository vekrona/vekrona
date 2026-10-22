#!/usr/bin/env bash
set -euo pipefail

fail() { echo "session-check FAILED: $*" >&2; exit 1; }

command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"

# shellcheck source=vm/session-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

session_ensure_up || fail "could not bring up or attach to a sway session"

systemctl --user start vekrona-shell.service || fail "vekrona-shell.service did not become active"

session_export_wayland_display || fail "could not find the sway session's WAYLAND_DISPLAY"

session_wait_until 30 qs -c vekrona-shell ipc show || fail "qs -c vekrona-shell ipc show failed"

xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml" || fail "xremap config failed to validate"

echo "session-check OK"
