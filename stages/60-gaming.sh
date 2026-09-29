#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

SCOPEBUDDY_URL="https://raw.githubusercontent.com/OpenGamingCollective/ScopeBuddy/1.5.0/bin/scopebuddy"
SCOPEBUDDY_BIN="/usr/local/bin/scopebuddy"
SCOPEBUDDY_LINK="/usr/local/bin/scb"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -sfL "$SCOPEBUDDY_URL" -o "$tmp" || die "failed to download scopebuddy: $SCOPEBUDDY_URL"
[[ -s "$tmp" ]] || die "downloaded scopebuddy is empty"

if [[ -f "$SCOPEBUDDY_BIN" ]] && cmp -s "$tmp" "$SCOPEBUDDY_BIN"; then
  log "scopebuddy up to date: $SCOPEBUDDY_BIN"
else
  log "installing scopebuddy: $SCOPEBUDDY_BIN"
  root install -D -m 0755 "$tmp" "$SCOPEBUDDY_BIN"
  cmp -s "$tmp" "$SCOPEBUDDY_BIN" || die "scopebuddy content mismatch after install"
fi
root chmod 0755 "$SCOPEBUDDY_BIN"

if [[ -L "$SCOPEBUDDY_LINK" && "$(readlink -f "$SCOPEBUDDY_LINK")" == "$(readlink -f "$SCOPEBUDDY_BIN")" ]]; then
  log "linked: $SCOPEBUDDY_LINK"
else
  root ln -sfn "$SCOPEBUDDY_BIN" "$SCOPEBUDDY_LINK"
fi
[[ "$(readlink -f "$SCOPEBUDDY_LINK")" == "$(readlink -f "$SCOPEBUDDY_BIN")" ]] || die "scb symlink failed"

assert "scb runs (SCB_NOSCOPE smoke test)" env SCB_NOSCOPE=1 scb -- true

ensure_pkg gamescope mangohud gamemode steam

log "Steam launch option: scb -- %command%"
