#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/stubs"
write_fake "$scratch/stubs/swaymsg" <<'F'
#!/usr/bin/env bash
[[ -z "${SWAY_OUTPUTS_FAIL:-}" ]] || exit 1
printf '%s\n' "$SWAY_OUTPUTS"
F
export PATH="$scratch/stubs:$PATH"

# What scopebuddy would hold after it sources the config.
scb_args() { bash -c 'set -eo pipefail; source "$1"; printf "%s" "$SCB_GAMESCOPE_ARGS"' _ "$ROOT/config/scopebuddy/scb.conf"; }

export SWAY_OUTPUTS='[{"name":"DP-1","focused":false,"current_mode":{"width":1920,"height":1080,"refresh":60000}},
{"name":"eDP-1","focused":true,"current_mode":{"width":2560,"height":1600,"refresh":59972}}]'
[[ "$(scb_args)" == "-f -W 2560 -H 1600 -r 60" ]] || die "a MacBook panel must get its own mode, not a fixed 4K: $(scb_args)"
log "ok: gamescope gets the focused output's size and refresh rate"

SWAY_OUTPUTS='[{"name":"DP-1","focused":true,"current_mode":{"width":3840,"height":2160,"refresh":239991}}]'
[[ "$(scb_args)" == "-f -W 3840 -H 2160 -r 240" ]] || die "a 4K 240 Hz monitor must give 240, not its truncated mHz: $(scb_args)"
log "ok: a fractional refresh rate rounds to the nearest Hz"

SWAY_OUTPUTS='[{"name":"DP-1","focused":false,"current_mode":{"width":3840,"height":2160,"refresh":240000}}]'
if scb_args 2>/dev/null; then die "no focused output must fail, not fall back to a guess"; fi
log "ok: no focused output fails"

SWAY_OUTPUTS_FAIL=1
export SWAY_OUTPUTS_FAIL
if scb_args 2>/dev/null; then die "an unreachable sway must fail, not fall back to a guess"; fi
log "ok: an unreachable sway fails"
