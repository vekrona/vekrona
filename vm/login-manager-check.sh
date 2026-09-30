#!/usr/bin/env bash
set -euo pipefail

fail() { echo "login-manager-check FAILED: $*" >&2; exit 1; }

active="$(systemctl is-active greetd 2>/dev/null || true)"
[[ "$active" == active ]] || fail "greetd not active: $active"

enabled="$(systemctl is-enabled greetd 2>/dev/null || true)"
[[ "$enabled" == enabled ]] || fail "greetd not enabled: $enabled"

target="$(systemctl get-default)"
[[ "$target" == graphical.target ]] || fail "default target is not graphical.target: $target"

echo "login-manager-check OK"
