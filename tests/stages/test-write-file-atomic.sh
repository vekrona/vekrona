#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
file="$work/theme"

write_file_atomic "$file" $'dark\n'
[[ "$(cat "$file")" == dark ]] || die "a new file must get the content"
[[ -z "$(find "$work" -mindepth 1 -not -path "$file")" ]] || die "a temp file was left behind: $(ls -A "$work")"
log "ok: a missing file is created and no temp file remains"

# A reader that opened or linked the old file must keep seeing it whole: the new content arrives by rename, not by truncating in place.
ln "$file" "$work/reader"
write_file_atomic "$file" $'light\n'
[[ "$(cat "$file")" == light ]] || die "an existing file must be replaced"
[[ "$(cat "$work/reader")" == dark ]] || die "the old file was rewritten in place"
log "ok: an existing file is replaced by rename, not rewritten in place"

write_file_atomic "$file" ""
[[ -f "$file" && ! -s "$file" ]] || die "empty content must give an empty file"
log "ok: empty content gives an empty file"

if (write_file_atomic "$work/missing-dir/theme" x) >/dev/null 2>&1; then die "a missing parent directory must fail"; fi
[[ ! -e "$work/missing-dir" ]] || die "a missing parent directory must not be created"
log "ok: a missing parent directory fails the write"

mkdir "$work/occupied"
if (write_file_atomic "$work/occupied" x) >/dev/null 2>&1; then die "a directory in the way must fail the write"; fi
[[ -z "$(find "$work" -maxdepth 1 -name '.*.tmp.*')" ]] || die "a failed write left a temp file: $(ls -A "$work")"
log "ok: a failed write removes its temp file"
