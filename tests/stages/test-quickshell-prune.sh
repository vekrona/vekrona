#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

runtime="$(mktemp -d)"
trap 'rm -rf "$runtime"' EXIT
dead_pid=4194304
mkdir -p "$runtime"/by-id/{live,dead,orphan} "$runtime/by-pid"
ln -s "$runtime/by-id/live" "$runtime/by-pid/$$"
ln -s "$runtime/by-id/dead" "$runtime/by-pid/$dead_pid"

prune_dead_quickshell_instances "$runtime"

[[ -d "$runtime/by-id/live" && -L "$runtime/by-pid/$$" ]] || die "the running instance's directory or pid link was removed"
[[ ! -e "$runtime/by-id/dead" && ! -e "$runtime/by-id/orphan" ]] || die "a dead instance's directory survived"
[[ ! -L "$runtime/by-pid/$dead_pid" ]] || die "the dead instance's pid link survived"
prune_dead_quickshell_instances "$runtime/missing"
log "ok: only exited Quickshell instances lose their runtime directories"
