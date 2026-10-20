#!/usr/bin/env bash
set -euo pipefail

fail() { echo "update-check FAILED: $*" >&2; exit 1; }

snapper_numbers() { sudo snapper -c root --csvout --no-headers list --columns number; }

vekrona_update_bin="$(command -v vekrona-update || true)"
[[ -n "$vekrona_update_bin" ]] || vekrona_update_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/vekrona-update"
[[ -x "$vekrona_update_bin" ]] || fail "vekrona-update not found (looked on PATH and at $vekrona_update_bin)"

before_count="$(snapper_numbers | wc -l)"
# polkit lets only an administrator at the machine start the update unit, and this check's ssh login is remote, so the
# update runs from a systemd user service, like the toast and the launcher run it.
systemd-run --user --pipe --wait --collect --quiet "$vekrona_update_bin" now 2>&1
after_count="$(snapper_numbers | wc -l)"

new_count=$((after_count - before_count))
[[ "$new_count" -ge 2 ]] || fail "expected at least 2 new snapper snapshots from vekrona-update, got $new_count"
echo "update-check: vekrona-update produced $new_count new snapshot(s)"

echo "update-check OK"
