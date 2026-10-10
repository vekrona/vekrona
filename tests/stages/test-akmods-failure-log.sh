#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

cache="$(mktemp -d)"
trap 'rm -rf "$cache"' EXIT
mkdir "$cache/wl" "$cache/nvidia"
kver=7.2.8-200.fc44.x86_64

if newest_akmods_failure_log "$cache" wl "$kver" >/dev/null; then die "no log must mean failure"; fi
[[ -z "$(newest_akmods_failure_log "$cache" wl "$kver" || true)" ]] || die "no log must print nothing"
log "ok: no failed build log gives no path"

# The older version's name sorts first, so a name-ordered pick would return it.
touch -d '2026-10-01 10:00' "$cache/wl/kmod-wl-7.2.8-200.fc44.x86_64-6.30.223-1-for-$kver.failed.log"
touch -d '2026-10-09 10:00' "$cache/wl/kmod-wl-7.2.8-200.fc44.x86_64-6.30.223-2-for-$kver.failed.log"
touch -d '2026-10-09 11:00' "$cache/wl/kmod-wl-7.2.8-200.fc44.x86_64-6.30.223-3-for-other-kernel.failed.log"
touch -d '2026-10-09 12:00' "$cache/nvidia/kmod-nvidia-1-for-$kver.failed.log"
[[ "$(newest_akmods_failure_log "$cache" wl "$kver")" == "$cache/wl/kmod-wl-7.2.8-200.fc44.x86_64-6.30.223-2-for-$kver.failed.log" ]] \
  || die "the newest log of this module and kernel must win, not the first by name"
log "ok: the most recently written log for this module and kernel is chosen"
