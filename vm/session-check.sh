#!/usr/bin/env bash
set -euo pipefail

fail() { echo "session-check FAILED: $*" >&2; exit 1; }

command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

session_ensure_up || fail "could not bring up or attach to a sway session"

systemctl --user start dms.service || fail "dms.service did not become active"

session_wait_until 30 dms ipc call lock status || fail "dms ipc call lock status failed"

xremap-wlroots --validate-config "$HOME/.config/xremap/config.yml" || fail "xremap config failed to validate"

echo "session-check OK"
