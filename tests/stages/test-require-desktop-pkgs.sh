#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"
# shellcheck source=dnf-fakes.sh
source "$REPO/tests/stages/dnf-fakes.sh"

mapfile -t all_desktop_pkgs < <(vekrona_desktop_pkgs)
packages "${all_desktop_pkgs[@]}"
require_desktop_pkgs
log "ok: with every desktop package installed the check passes"

rm -f "$FAKE_RPMDB/qrencode" "$FAKE_RPMDB/libnotify"
if failure="$(require_desktop_pkgs 2>&1)"; then
  die "a missing desktop package must fail the check"
fi
[[ "$failure" == *"desktop packages not installed: "*qrencode*libnotify*"install.sh 30"* || "$failure" == *"desktop packages not installed: "*libnotify*qrencode*"install.sh 30"* ]] ||
  die "the failure must name every missing package and the stage that installs them: $failure"
[[ "$failure" != *sway* ]] || die "the failure must not name an installed package: $failure"
log "ok: missing desktop packages are all named, with the stage that installs them"
