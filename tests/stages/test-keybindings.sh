#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/lib/common.sh"
tool="$ROOT/bin/vekrona-keybindings"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# vekrona-keybindings reads $HOME/.config/{sway,xremap}; point it at the repo's config.
mkdir -p "$scratch/home/.config"
ln -s "$ROOT/config/sway" "$scratch/home/.config/sway"
mkdir "$scratch/home/.config/xremap"
cp "$ROOT/config/xremap/config.yml" "$scratch/home/.config/xremap/config.yml"

run_check() { HOME="$scratch/home" "$tool" --check 2>"$scratch/stderr"; }

run_check || die "repo config fails --check: $(cat "$scratch/stderr")"
log "ok: repo config passes --check"

# Sway binds Mod4+q (kill), so remapping Super-q in xremap shadows it.
sed -i 's/^      Super-c: C-c$/&\n      Super-q: C-q/' "$scratch/home/.config/xremap/config.yml"
grep -qxF '      Super-q: C-q' "$scratch/home/.config/xremap/config.yml" || die "test setup: Super-q was not added to cmd-layer"
if run_check; then
  die "--check accepted a xremap Super-q remap that shadows the Sway Mod4+q binding"
fi
grep -q 'can never fire.*Mod4+q' "$scratch/stderr" || die "--check failed for the wrong reason: $(cat "$scratch/stderr")"
log "ok: --check rejects a xremap remap that shadows a Sway binding"
