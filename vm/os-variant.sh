#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <fedora-release>" >&2; exit 2; }
release="$1"
wanted="fedora$release"

known="$(osinfo-query --fields=short-id os | grep -oE 'fedora[0-9]+' | sort -V)" \
  || { echo "could not list Fedora releases from the osinfo database; run 'make -C vm deps'" >&2; exit 1; }

if grep -qx "$wanted" <<<"$known"; then
  echo "$wanted"
  exit 0
fi

newest_known="$(tail -n1 <<<"$known")"
echo "warning: osinfo database does not know $wanted, using the $newest_known hardware profile; the guest is still Fedora $release. Update the database with: osinfo-db-import --user --latest" >&2
echo "$newest_known"
