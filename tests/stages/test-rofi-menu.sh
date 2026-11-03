#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# The tool runs from a scratch tree whose theme renderer is a stub; rofi and the error reporter are stubs at the command boundary.
tree="$scratch/tree"
stubs="$scratch/stubs"
mkdir -p "$tree/bin" "$stubs"
cp -r "$ROOT/lib" "$tree/"
cp "$ROOT/bin/vekrona-rofi-menu" "$tree/bin/"
tool="$tree/bin/vekrona-rofi-menu"
printf '#!/bin/sh\n[ -z "$THEME_FAIL" ] || { echo "no theme" >&2; exit 4; }\necho "* { stub-theme: yes; }"\n' > "$tree/bin/vekrona-render-theme"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/rofi.argv"\ncat > "%s/rofi.stdin"\n[ -z "$ROFI_STDERR" ] || echo "$ROFI_STDERR" >&2\n[ -z "$ROFI_OUT" ] || echo "$ROFI_OUT"\nexit "${ROFI_STATUS:-0}"\n' "$scratch" "$scratch" > "$stubs/rofi"
printf '#!/bin/sh\necho "$*" >> "%s/reported"\n' "$scratch" > "$stubs/reporter"
chmod +x "$tree/bin/vekrona-render-theme" "$stubs"/*
export VEKRONA_ERROR_REPORTER="$stubs/reporter"
export ROFI_STDERR="" ROFI_OUT="" ROFI_STATUS=0 THEME_FAIL=""

menu() {
  rm -f "$scratch/reported" "$scratch/rofi.argv" "$scratch/rofi.stdin"
  rc=0
  out="$(PATH="$stubs:$PATH" "$tool" "$@" <<<$'alpha\nbeta' 2>"$scratch/stderr")" || rc=$?
}
argv_has() { grep -qxF -- "$1" "$scratch/rofi.argv"; }

ROFI_OUT=beta menu --prompt Pick
[[ "$rc" == 0 && "$out" == beta ]] || die "a chosen entry must be printed with exit 0: exit $rc, '$out', $(cat "$scratch/stderr")"
[[ "$(<"$scratch/rofi.stdin")" == $'alpha\nbeta' ]] || die "the entries do not reach rofi: $(cat "$scratch/rofi.stdin")"
argv_has Pick || die "the prompt does not reach rofi: $(cat "$scratch/rofi.argv")"
argv_has '* { stub-theme: yes; }' || die "rofi is not themed by vekrona-render-theme rofi: $(cat "$scratch/rofi.argv")"
! argv_has -mesg && ! argv_has -format || die "-mesg and -format must be off unless asked for: $(cat "$scratch/rofi.argv")"
log "ok: a chosen entry is printed, themed, with the entries on rofi's stdin"

ROFI_OUT=1 menu --prompt Pick --message "A hint" --index
[[ "$rc" == 0 && "$out" == 1 ]] || die "--index must print rofi's answer: exit $rc, '$out'"
argv_has -mesg && argv_has "A hint" && argv_has -format && argv_has i || die "--message and --index do not reach rofi: $(cat "$scratch/rofi.argv")"
log "ok: --message and --index reach rofi"

ROFI_STATUS=1 menu --prompt Pick
[[ "$rc" == 1 && -z "$out" && ! -s "$scratch/stderr" && ! -e "$scratch/reported" ]] \
  || die "Esc must end with exit 1, no output and no report: exit $rc, '$out', $(cat "$scratch/stderr")"
log "ok: Esc is a quiet cancel"

ROFI_STATUS=0 ROFI_OUT="" menu --prompt Pick
[[ "$rc" == 1 && -z "$out" && ! -e "$scratch/reported" ]] || die "a menu closed with no choice is a cancel: exit $rc, '$out'"
log "ok: an empty choice is a cancel"

ROFI_STATUS=65 ROFI_STDERR="theme parse error" menu --prompt Pick
[[ "$rc" == 3 && -z "$out" ]] || die "a rofi that failed must end with exit 3 and no output: exit $rc, '$out'"
grep -q 'rofi exited with status 65: theme parse error' "$scratch/stderr" || die "rofi's status and stderr are not reported: $(cat "$scratch/stderr")"
grep -q 'rofi exited with status 65: theme parse error' "$scratch/reported" || die "the rofi failure is not recorded: $(cat "$scratch/reported" 2>&1)"
log "ok: a rofi failure is not taken for Esc, and is recorded with its status and stderr"

THEME_FAIL=1 menu --prompt Pick
[[ "$rc" == 3 && ! -e "$scratch/rofi.argv" ]] || die "a failing theme renderer must stop before rofi starts: exit $rc"
grep -q 'vekrona-render-theme rofi failed' "$scratch/reported" || die "the renderer failure is not recorded: $(cat "$scratch/reported" 2>&1)"
log "ok: a failing theme renderer fails the menu"

menu --message "no prompt"
[[ "$rc" == 2 && ! -e "$scratch/rofi.argv" ]] || die "a call without --prompt is a usage error: exit $rc"
grep -q usage "$scratch/stderr" || die "no usage on stderr: $(cat "$scratch/stderr")"
log "ok: a call without --prompt prints the usage"
