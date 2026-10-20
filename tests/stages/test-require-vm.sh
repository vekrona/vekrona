#!/usr/bin/env bash
# The guard that keeps tests off the host lets the vekrona-dev guest and GitHub Actions' container through, and nothing else.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
touch "$work/marker"

# Whether the guard lets a test run on a machine that is not the guest, with GITHUB_ACTIONS=$1 and container markers $2...
allowed() {
  local actions="$1"
  shift
  (
    source "$ROOT/tests/require-vm.sh"
    in_vekrona_dev_guest() { return 1; }
    CONTAINER_MARKERS=("$@")
    GITHUB_ACTIONS="$actions"
    require_vm /nowhere/test.sh
  ) 2>/dev/null
}

allowed true "$work/marker" || die "GitHub Actions in a container must be allowed"
allowed true "$work/none" "$work/marker" || die "any one container marker must do"
! allowed true "$work/none" || die "GitHub Actions outside a container (no marker) must be refused"
! allowed "" "$work/marker" || die "a container outside GitHub Actions must be refused"
! allowed yes "$work/marker" || die "GITHUB_ACTIONS must be exactly true"
! allowed false "$work/marker" || die "GITHUB_ACTIONS=false must be refused"
log "ok: only GitHub Actions in a container passes besides the guest"

bash "$ROOT/tests/require-vm.sh" || die "the guard run on its own must pass in the guest"
python3 -c "import sys; sys.path.insert(0, '$ROOT/tests'); from require_vm import require_vm; require_vm()" || die "the Python guard must pass in the guest"
log "ok: the guard passes in the guest, from bash and from Python"
