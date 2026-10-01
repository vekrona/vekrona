#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

SCOPEBUDDY_URL="https://raw.githubusercontent.com/OpenGamingCollective/ScopeBuddy/1.5.0/bin/scopebuddy"
SCOPEBUDDY_SHA256="715aa8cbb6722e88e6ec77e89a407049cd97fa316ef6618d4535ce46969a587f"
SCOPEBUDDY_BIN="/usr/local/bin/scopebuddy"
SCOPEBUDDY_LINK="/usr/local/bin/scb"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -sfL "$SCOPEBUDDY_URL" -o "$tmp" || die "failed to download scopebuddy: $SCOPEBUDDY_URL"
[[ -s "$tmp" ]] || die "downloaded scopebuddy is empty"
tmp_sha256="$(sha256sum "$tmp" | awk '{print $1}')"
[[ "$tmp_sha256" == "$SCOPEBUDDY_SHA256" ]] || die "scopebuddy sha256 mismatch: got $tmp_sha256, expected $SCOPEBUDDY_SHA256"

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

for p in gamescope mangohud gamemode steam python3-vdf; do
  assert "package present: $p" pkg_installed "$p"
done

log "Steam launch option: scb -- %command%"

STEAM_CONFIG_VDF="$HOME/.local/share/Steam/config/config.vdf"

steam_is_running() {
  pgrep -u "$(id -u)" -x steam >/dev/null || pgrep -u "$(id -u)" -f steamwebhelper >/dev/null
}

ensure_steam_proton_for_all_titles() {
  local config="$1" dir tmp
  dir="$(dirname "$config")"
  tmp="$(mktemp "$dir/.$(basename "$config").XXXXXX")"
  if ! python3 - "$config" > "$tmp" <<'PYEOF'
import sys
import vdf

path = sys.argv[1]


def find_key(d, key):
    if key in d:
        return key
    for k in d:
        if isinstance(k, str) and k.lower() == key.lower():
            return k
    return None


def child(d, key):
    found = find_key(d, key)
    if found is None:
        d[key] = {}
        return d[key]
    value = d[found]
    if not isinstance(value, dict):
        raise SystemExit(f"expected a section at {key!r}, found {type(value).__name__}")
    return value


with open(path) as f:
    data = vdf.load(f)

node = data
for key in ("InstallConfigStore", "Software", "Valve", "Steam", "CompatToolMapping"):
    node = child(node, key)

node["0"] = {"name": "proton_experimental", "config": "", "priority": "75"}

vdf.dump(data, sys.stdout, pretty=True)
PYEOF
  then
    rm -f "$tmp"
    die "failed to update Steam config: $config"
  fi
  [[ -s "$tmp" ]] || { rm -f "$tmp"; die "empty output while updating Steam config: $config"; }
  if cmp -s "$tmp" "$config"; then
    rm -f "$tmp"
    log "Steam Play for all titles already enabled"
    return 0
  fi
  chmod --reference="$config" "$tmp"
  mv "$tmp" "$config"
  log "Steam Play for all titles enabled (proton_experimental)"
}

if [[ ! -f "$STEAM_CONFIG_VDF" ]]; then
  log "Steam never launched: launch Steam once, quit it, then run ./install.sh 60 to enable Steam Play for all titles"
elif steam_is_running; then
  die "Steam is running; quit it, then re-run ./install.sh 60 (Steam overwrites config.vdf on exit)"
else
  ensure_steam_proton_for_all_titles "$STEAM_CONFIG_VDF"
fi
