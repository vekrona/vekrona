#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <fedora-release>" >&2; exit 2; }
release="$1"

redirector_url="https://download.fedoraproject.org/pub/fedora/linux/releases/$release/Everything/x86_64/os/"

tree_url="$(curl -sS -f -o /dev/null -w '%{url_effective}' -L --max-redirs 1 -I "$redirector_url")" \
  || { echo "could not resolve a mirror for $redirector_url" >&2; exit 1; }

[[ "$tree_url" != "$redirector_url" ]] \
  || { echo "$redirector_url did not redirect to a mirror; refusing to pin the install tree to the redirector itself" >&2; exit 1; }

[[ "$tree_url" == */ ]] || { echo "mirror redirect for $redirector_url resolved to a non-directory URL: $tree_url" >&2; exit 1; }

for file in .treeinfo images/pxeboot/vmlinuz images/pxeboot/initrd.img; do
  curl -sS -f -o /dev/null -I "$tree_url$file" \
    || { echo "mirror $tree_url does not serve $file (fetched from $tree_url$file)" >&2; exit 1; }
done

echo "$tree_url"
