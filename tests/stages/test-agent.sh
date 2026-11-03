#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-agent"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/config" SCRATCH="$scratch"
mkdir -p "$HOME"

stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }
stub claude 'exit 0'
stub ghostty 'exit 0'
stub qs 'exit 0'
stub systemctl 'echo "PATH=/usr/bin"'
stub systemd-run 'echo "Failed to start transient service: Access denied" >&2; exit 1'
stub reporter 'echo "$*" >> "$SCRATCH/reported"'
export VEKRONA_ERROR_REPORTER="$stubs/reporter"

agent() {
  rc=0
  out="$(PATH="$stubs:$PATH" "$tool" "$@" 2>"$scratch/stderr")" || rc=$?
}

agent get
[[ "$rc" == 0 && -z "$out" ]] || die "get with no default must print nothing and succeed: exit $rc, '$out', $(cat "$scratch/stderr")"
agent set claude
[[ "$rc" == 0 ]] || die "set claude failed: $(cat "$scratch/stderr")"
agent get
[[ "$rc" == 0 && "$out" == claude ]] || die "get must print the default: exit $rc, '$out'"
log "ok: get prints the default, or nothing when none is set"

agent --prompt hello
[[ "$rc" == 1 ]] || die "a launch whose systemd-run failed must fail, got exit $rc"
grep -q 'Access denied' "$scratch/stderr" || die "the reason systemd-run gave is lost: $(cat "$scratch/stderr")"
grep -q 'Access denied' "$scratch/reported" || die "the reported failure lacks the reason: $(cat "$scratch/reported" 2>&1)"
log "ok: a failing systemd-run is reported with its own message"

# The picker: the tool runs from a scratch tree with the real vekrona-rofi-menu, a stub theme renderer and a stub rofi that
# answers like the user does.
tree="$scratch/tree"
mkdir -p "$tree/bin"
cp -r "$ROOT/lib" "$tree/"
cp "$tool" "$ROOT/bin/vekrona-rofi-menu" "$tree/bin/"
printf '#!/bin/sh\necho "* {}"\n' > "$tree/bin/vekrona-render-theme"
chmod +x "$tree/bin/vekrona-render-theme"
stub rofi 'cat > "$SCRATCH/rofi.stdin"; [ -z "$ROFI_STDERR" ] || echo "$ROFI_STDERR" >&2; [ -z "$ROFI_OUT" ] || echo "$ROFI_OUT"; exit "${ROFI_STATUS:-0}"'
export ROFI_STDERR="" ROFI_OUT="" ROFI_STATUS=0

pick() {
  rm -f "$scratch/reported" "$scratch/rofi.stdin"
  rc=0
  out="$(PATH="$stubs:$PATH" "$tree/bin/vekrona-agent" --choose --dry-run 2>"$scratch/stderr" | tr '\0' ' ')" || rc=$?
}

ROFI_OUT=claude pick
[[ "$rc" == 0 && "$out" == *"$stubs/claude"* ]] || die "the picked tool must be launched: exit $rc, '$out', $(cat "$scratch/stderr")"
grep -qxF claude "$scratch/rofi.stdin" || die "the installed tools are not offered to the picker: $(cat "$scratch/rofi.stdin")"
log "ok: the picker offers the installed tools and launches the one chosen"

ROFI_STATUS=1 pick
[[ "$rc" == 0 && -z "$out" && ! -e "$scratch/reported" ]] || die "cancelling the picker must end quietly without a launch: exit $rc, '$out', $(cat "$scratch/stderr")"
log "ok: cancelling the picker launches nothing and records nothing"

ROFI_STATUS=65 ROFI_STDERR="theme parse error" pick
[[ "$rc" == 1 && -z "$out" ]] || die "a rofi that failed must fail the picker without a launch: exit $rc, '$out'"
[[ "$(grep -c 'rofi exited with status 65: theme parse error' "$scratch/reported")" == 1 ]] || die "the rofi failure must be recorded exactly once: $(cat "$scratch/reported" 2>&1)"
log "ok: a rofi failure is not taken for Esc and is recorded once"
