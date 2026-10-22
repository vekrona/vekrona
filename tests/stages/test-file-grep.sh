#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

printf 'alpha\nbeta\n' > "$scratch/file"
mkdir "$scratch/dir"

file_grep_q -x alpha "$scratch/file" || die "a matching line was not found"
log "ok: match is status 0"

if file_grep_q -x gamma "$scratch/file"; then die "a missing line was reported as found"; fi
log "ok: no match is status 1"

for target in "$scratch/dir" "$scratch/missing"; do
  if (file_grep_q -x alpha "$target") 2>"$scratch/stderr"; then die "grep error on $target was read as a match"; fi
  grep -q 'exit status 2' "$scratch/stderr" || die "grep error on $target was not reported: $(cat "$scratch/stderr")"
done
log "ok: grep errors are fatal, not 'absent'"

if (VERSIONLOCK_FILE="$scratch/dir" versionlock_has pkg) 2>/dev/null; then die "unsearchable versionlock file read as present"; fi
VERSIONLOCK_FILE="$scratch/missing"
! versionlock_has pkg || die "a missing versionlock file must mean not locked"
log "ok: versionlock_has distinguishes absent from unreadable"

printf 'gpgkey=a\nname=b\ngpgkey=a\n' >"$scratch/repo"
[[ "$(file_grep '^gpgkey=' "$scratch/repo" | sort -u)" == gpgkey=a ]] || die "file_grep did not print the matching lines"
[[ -z "$(file_grep '^nothing=' "$scratch/repo")" ]] || die "file_grep printed something for no match"
file_grep '^nothing=' "$scratch/repo" || die "no match must end file_grep with status 0"
log "ok: file_grep prints matches, and no match is not an error"

if (file_grep '^gpgkey=' "$scratch/missing") 2>"$scratch/stderr"; then die "file_grep read an unreadable file as 'no match'"; fi
grep -q 'exit status 2' "$scratch/stderr" || die "file_grep did not report the grep error: $(cat "$scratch/stderr")"
log "ok: file_grep dies on an unreadable file"
