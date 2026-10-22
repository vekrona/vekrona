#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

path_line="$(grep '^PATH=' "$ROOT/config/environment.d/vekrona.conf")"
[[ "$path_line" == 'PATH=$HOME/.local/bin:$PATH:$HOME/.nix-profile/bin' ]] \
  || die "~/.nix-profile/bin must come after the system PATH, or a nix package shadows a system tool: $path_line"
log "ok: ~/.local/bin leads the PATH and the nix profile trails it"
