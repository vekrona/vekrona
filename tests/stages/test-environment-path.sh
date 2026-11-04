#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

path_line="$(grep '^PATH=' "$ROOT/config/environment.d/vekrona.conf")"
[[ "$path_line" == 'PATH=$HOME/.local/bin:$PATH' ]] \
  || die "~/.local/bin must lead the PATH: $path_line"
log "ok: ~/.local/bin leads the PATH"
