#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

dm_target="$(dm_unit_target || true)"

if [[ -z "$dm_target" || "$dm_target" == greetd.service ]]; then
  enable_greetd_login_manager
else
  log "display manager already enabled: $dm_target; leaving it alone, 90a-switch-dm is the migration path for an existing installation"
fi
