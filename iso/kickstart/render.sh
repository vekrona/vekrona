#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $(basename "$0") <release|test> <output-file> [--ssh-pubkey FILE]" >&2; exit 2; }

[[ $# -ge 2 ]] || usage
variant="$1"
out="$2"
shift 2

ssh_pubkey_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-pubkey) [[ $# -ge 2 ]] || usage; ssh_pubkey_file="$2"; shift 2 ;;
    *) usage ;;
  esac
done

case "$variant" in
  release|test) ;;
  *) echo "unknown variant: $variant (expected release or test)" >&2; exit 1 ;;
esac

if [[ "$variant" == test ]]; then
  [[ -n "$ssh_pubkey_file" ]] || { echo "test variant requires --ssh-pubkey FILE" >&2; exit 1; }
  [[ -r "$ssh_pubkey_file" ]] || { echo "ssh pubkey file not readable: $ssh_pubkey_file" >&2; exit 1; }
fi

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat "$dir/$variant.pre.ks" "$dir/common.ks.tmpl" "$dir/$variant.post.ks" > "$tmp"

if [[ "$variant" == test ]]; then
  key="$(cat "$ssh_pubkey_file")"
  python3 - "$tmp" "$key" <<'PYEOF'
import sys
path, key = sys.argv[1], sys.argv[2]
text = open(path).read()
if "@SSH_PUBKEY@" not in text:
    sys.exit("render.sh: @SSH_PUBKEY@ placeholder not found in assembled kickstart")
open(path, "w").write(text.replace("@SSH_PUBKEY@", key.strip()))
PYEOF
fi

mkdir -p "$(dirname "$out")"
mv "$tmp" "$out"
trap - EXIT
echo "$out"
