#!/usr/bin/env bash
# The system monospace font is Atkinson Hyperlegible Mono (Nerd build), and the documented Ghostty snippet takes the backtick, which the Nerd build lacks, from the Google build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

GUEST_GHOSTTY_FONTS=/mnt/vekrona/docs/ghostty-fonts.conf

show_face() { vekrona-dev run ghostty --config-default-files=false --config-file="$GUEST_GHOSTTY_FONTS" +show-face --string="$1"; }

# The first mono family of the design tokens that is not a generic CSS family.
TOKEN_MONO="$(jq -er '.type.families.mono | split(",")[0] | gsub("^\\s*\"|\"\\s*$"; "")' "$ROOT/config/tokens.json")"

monospace="$(vekrona-dev run fc-match -f '%{family}' monospace)"
[[ "$monospace" == "$TOKEN_MONO"* ]] || die "fc-match monospace must start with the design's first mono family $TOKEN_MONO, but it is: $monospace"
log "ok: fc-match monospace -> $monospace"

backtick="$(show_face '`')"
[[ "$backtick" == *"Atkinson Hyperlegible Mono"* ]] || die "Ghostty must take the backtick from Atkinson Hyperlegible Mono (the Nerd build lacks it), but it reports: $backtick"
log "ok: $backtick"

letter="$(show_face a)"
[[ "$letter" == *"${TOKEN_MONO%% *}"* ]] || die "Ghostty must draw letters from $TOKEN_MONO, but it reports: $letter"
log "ok: $letter"
