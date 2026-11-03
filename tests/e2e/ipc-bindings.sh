#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

SWAY_CONFIG="$ROOT/config/sway/config"

vekrona-dev session

shown="$(vekrona-dev sh qs -c vekrona-shell ipc show)"
calls="$(grep -oE 'qs -c vekrona-shell ipc call [A-Za-z]+ [A-Za-z]+' "$SWAY_CONFIG" | sort -u)"
[[ -n "$calls" ]] || die "$SWAY_CONFIG has no vekrona-shell ipc binding"
while read -r _ _ _ _ _ target name; do
  awk -v target="$target" -v function_name="$name" '
    $1 == "target" { current = $2 }
    current == target && $1 == "function" && $2 ~ ("^" function_name "\\(") { found = 1 }
    END { exit !found }' <<<"$shown" || die "sway binds '$target $name', but 'qs -c vekrona-shell ipc show' does not list it"
done <<<"$calls"
log "ok: every ipc call in the sway config exists in the running shell"

# A binding may run a program through a `set $name program args` variable of the config: the program is the first word of its value.
bound_program() {
  local word="$1" value
  [[ "$word" == \$* ]] || { printf '%s\n' "$word"; return; }
  value="$(sed -nE "s/^set \\\$${word#\$} (.+)$/\1/p" "$SWAY_CONFIG")"
  [[ -n "$value" ]] || die "sway runs $word, which the config does not set"
  printf '%s\n' "${value%% *}"
}
binaries="$(grep -E '^[[:space:]]*bindsym' "$SWAY_CONFIG" | grep -oE ' exec (--no-startup-id )?[^ ]+' | awk '{print $NF}' | sort -u | while read -r word; do bound_program "$word"; done | sort -u)"
while read -r binary; do
  vekrona-dev sh bash -c 'command -v "$1" >/dev/null' _ "$binary" || die "sway binds '$binary', which is not installed in the guest"
done <<<"$binaries"
log "ok: every program the bindings run exists in the guest"
