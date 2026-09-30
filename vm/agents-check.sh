#!/usr/bin/env bash
set -euo pipefail

fail() { echo "agents-check FAILED: $*" >&2; exit 1; }

MISE_SYSTEM_DATA_DIR=/usr/local/share/mise
MISE_SYSTEM_CONFIG_DIR=/etc/mise

for t in codex pi opencode cursor-agent; do
  bin="$MISE_SYSTEM_DATA_DIR/shims/$t"
  [[ -x "$bin" ]] || fail "$t shim missing or not executable: $bin"
  version="$("$bin" --version 2>&1)" || fail "$t --version failed: $version"
  echo "agents-check: $t -> $bin ($version)"
done

version="$(claude --version 2>&1)" || fail "claude --version failed: $version"
echo "agents-check: claude -> $(command -v claude) ($version)"

resolves_in_login_shell() { bash -lc "command -v $1" >/dev/null 2>&1; }
for t in claude codex pi opencode cursor-agent; do
  resolves_in_login_shell "$t" \
    || fail "$t does not resolve on PATH in a login shell (check /etc/profile.d/vekrona-mise.sh)"
done
echo "agents-check: all harnesses resolve on PATH in a login shell"

owner_pkg="$(rpm -qf /usr/bin/claude 2>/dev/null || true)"
[[ "$owner_pkg" == claude-code-* ]] || fail "/usr/bin/claude is not owned by claude-code: $owner_pkg"

sig="$(rpm -q --qf '%{RSAHEADER:pgpsig}\n' claude-code 2>/dev/null || true)"
keyid="$(grep -oE 'Key ID [0-9A-Fa-f]+' <<<"$sig" | awk '{print tolower($3)}')"
[[ "${keyid: -8}" == "1a7ecace" ]] || fail "claude-code signature key id mismatch: $sig"
echo "agents-check: claude-code signed by key id ...${keyid: -8}"

for d in "$MISE_SYSTEM_DATA_DIR" "$MISE_SYSTEM_CONFIG_DIR"; do
  touch "$d/.agents-check-write-test" 2>/dev/null && fail "writing into $d succeeded, expected Permission denied"
done
echo "agents-check: mise system dirs are not writable by $(id -un)"

snapper_numbers() { sudo snapper -c root --csvout --no-headers list --columns number; }

vekrona_update_bin="$(command -v vekrona-update || true)"
[[ -n "$vekrona_update_bin" ]] || vekrona_update_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/vekrona-update"
[[ -x "$vekrona_update_bin" ]] || fail "vekrona-update not found (looked on PATH and at $vekrona_update_bin)"

before_count="$(snapper_numbers | wc -l)"
"$vekrona_update_bin"
after_count="$(snapper_numbers | wc -l)"

new_count=$((after_count - before_count))
[[ "$new_count" -ge 2 ]] || fail "expected at least 2 new snapper snapshots from vekrona-update, got $new_count"
echo "agents-check: vekrona-update produced $new_count new snapshot(s)"

echo "agents-check OK"
