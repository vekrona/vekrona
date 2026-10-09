#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
holder=""
release() { [[ -z "$holder" ]] || kill "$holder"; holder=""; }
trap 'release; rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/store" "$work/elsewhere"
mkfifo "$work/ready"
printf '#!/bin/sh\nexec "$@"\n' > "$work/bin/sudo"
chmod +x "$work/bin/sudo"
export PATH="$work/bin:$PATH"

# Runs the given subshell body, which must report readiness through $work/ready before it execs sleep; sets holder to sleep's PID.
hold() {
  ( eval "$1"; echo "$BASHPID" > "$work/ready"; exec sleep infinity ) &
  read -r holder < "$work/ready"
}

in_use_message() { (die_if_path_in_use "$work/store") 2>&1 || true; }

die_if_path_in_use "$work/store"
log "ok: an unused directory passes"

hold "cd '$work/elsewhere'"
die_if_path_in_use "$work/store"
log "ok: a process elsewhere on the same filesystem does not count"
release

hold "cd '$work/store'"
message="$(in_use_message)"
[[ "$message" == *"$holder sleep"* ]] || die "a process with its working directory inside was not reported: $message"
log "ok: a process whose working directory is inside is reported with its PID and command"
release

hold "exec 7> '$work/store/open-file'"
message="$(in_use_message)"
[[ "$message" == *"$holder sleep"* ]] || die "a process holding an open file inside was not reported: $message"
log "ok: a process holding an open file inside is reported"
