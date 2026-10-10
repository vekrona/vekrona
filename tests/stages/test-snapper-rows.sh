#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

csv=$'0,single,\n5,pre,number\n6,post,number\n9,pre,number\n10,post,number'

[[ "$(snapper_rows_after 6 <<<"$csv")" == $'9,pre,number\n10,post,number' ]] \
  || die "only snapshots numbered above the baseline may be kept (10 sorts below 9 as text)"
log "ok: snapper_rows_after keeps the rows numbered above the baseline, compared as numbers"

[[ -z "$(snapper_rows_after 10 <<<"$csv")" ]] || die "no snapshot above the newest one may be left"
log "ok: nothing is left when no snapshot is newer than the baseline"

if (snapper_rows_after "" <<<"$csv") 2>/dev/null; then die "an empty baseline must be refused"; fi
if (snapper_rows_after "lizard" <<<"$csv") 2>/dev/null; then die "a non-numeric baseline must be refused"; fi
log "ok: a baseline that is not a snapshot number is refused"
