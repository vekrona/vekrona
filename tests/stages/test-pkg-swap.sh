#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"
# shellcheck source=dnf-fakes.sh
source "$REPO/tests/stages/dnf-fakes.sh"

packages libswscale-free libavcodec-free
ensure_pkg_swapped ffmpeg-free ffmpeg
installed ffmpeg || die "ffmpeg must replace the free ffmpeg libraries even without the ffmpeg-free package"
! installed libswscale-free || die "the conflicting free library must be gone"
log "ok: free ffmpeg libraries alone are replaced"

packages ffmpeg-free libswscale-free
ensure_pkg_swapped ffmpeg-free ffmpeg
{ installed ffmpeg && ! installed ffmpeg-free; } || die "ffmpeg-free must be swapped for ffmpeg"
log "ok: ffmpeg-free is swapped"

packages
ensure_pkg_swapped ffmpeg-free ffmpeg
installed ffmpeg || die "ffmpeg must be installed on a system without any free variant"
log "ok: a clean system gets ffmpeg"

packages ffmpeg
ensure_pkg_swapped ffmpeg-free ffmpeg
[[ ! -e "$FAKE_DNF_LOG" ]] || die "an already swapped system must not touch dnf: $(cat "$FAKE_DNF_LOG")"
log "ok: an already swapped system is left alone"

packages libswscale-free
if failure="$(FAKE_DNF_FAIL=1 ensure_pkg_swapped ffmpeg-free ffmpeg 2>&1)"; then
  die "a failing dnf must fail the swap"
fi
[[ "$failure" == *"package did not install: ffmpeg"* ]] || die "a failing dnf must say which package did not install: $failure"
log "ok: a failing dnf fails the swap"
