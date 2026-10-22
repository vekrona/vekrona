#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-media-raise"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }

# BUS_REPLY is what the bus says about the player, SWAY_WINDOW_PID the one process sway has a window for.
stub busctl '[[ -n "${BUS_REPLY:-}" ]] || { echo "Failed to call method: no such name" >&2; exit 1; }
echo "$BUS_REPLY"'
stub swaymsg 'if [[ "$1" == "[pid=${SWAY_WINDOW_PID:-}] focus" ]]; then exit 0; fi
echo "No matching node" >&2; exit 1'

raise() {
  rc=0
  PATH="$stubs:$PATH" "$tool" "$@" >/dev/null 2>"$scratch/stderr" || rc=$?
}
expect_failure() {
  [[ "$rc" == 1 ]] || die "$1: expected exit 1, got $rc"
  grep -q "^vekrona-media-raise: $2" "$scratch/stderr" || die "$1: the message must start with the tool's name and say '$2': $(cat "$scratch/stderr")"
}

BUS_REPLY="" raise org.mpris.MediaPlayer2.gone
expect_failure "unknown player" "cannot ask the bus"
log "ok: a name the bus does not know fails with a message"

BUS_REPLY="s nonsense" raise org.mpris.MediaPlayer2.odd
expect_failure "odd reply" "unexpected reply"
log "ok: a reply that is not a pid fails with a message"

BUS_REPLY="u $$" SWAY_WINDOW_PID=$$ raise org.mpris.MediaPlayer2.here
[[ "$rc" == 0 ]] || die "a player owning a window: expected exit 0, got $rc: $(cat "$scratch/stderr")"
log "ok: the player's own window is focused"

BUS_REPLY="u 99999999" raise org.mpris.MediaPlayer2.vanished
expect_failure "vanished owner" "cannot read the parent of process 99999999"
log "ok: an owner that exited while its ancestors were walked fails with a message"
