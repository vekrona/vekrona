#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"

bind_re='^[[:space:]]*bindsym[[:space:]]+((--[^[:space:]]+[[:space:]]+)*)[^[:space:]]+[[:space:]]+(.+)$'
repeating_re='^(focus |move |resize |workspace number |split[vh]$|mode "default"$|exec vekrona-app-switch |exec dms ipc call (audio|brightness) (increment|decrement) |exec brightnessctl )'

checked=0
offenders=()
while IFS= read -r line; do
  [[ "$line" =~ $bind_re ]] || continue
  checked=$((checked + 1))
  flags="${BASH_REMATCH[1]}" command="${BASH_REMATCH[3]}"
  [[ "$flags" == *--no-repeat* || "$command" =~ $repeating_re ]] || offenders+=("$line")
done <"$ROOT/config/sway/config"

((checked > 0)) || die "no bindsym found in config/sway/config"
((${#offenders[@]} == 0)) || die "holding these keys would rerun the command on every key repeat; add --no-repeat:
$(printf '%s\n' "${offenders[@]}")"
log "ok: only stepping actions repeat while a key is held ($checked bindings)"
