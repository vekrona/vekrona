#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub body is written to a file literally and expands when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-webapp"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/stubs"
printf '#!/bin/sh\necho "$*" >> "%s/firefox.log"\n' "$scratch" > "$scratch/stubs/firefox"
chmod +x "$scratch/stubs/firefox"

webapp() {
  rm -f "$scratch/firefox.log"
  rc=0
  PATH="$scratch/stubs:$PATH" "$tool" "$@" >/dev/null 2>"$scratch/stderr" || rc=$?
}

webapp spotify
[[ "$rc" == 0 ]] || die "a known webapp failed: $(cat "$scratch/stderr")"
grep -qx -- "--name vekrona-spotify -P vekrona-spotify --new-window $(cat "$ROOT/config/firefox/webapps/spotify/url")" "$scratch/firefox.log" \
  || die "firefox got the wrong arguments: $(cat "$scratch/firefox.log")"
log "ok: a known webapp opens its own address in its own profile"

# A name that only leads to a webapp directory by a path is not a webapp.
for name in ../webapps/spotify . .. ../../.. spotify/ spotify/. -spotify lizard; do
  webapp "$name"
  [[ "$rc" == 1 && ! -e "$scratch/firefox.log" ]] || die "'$name' must be refused without starting Firefox: exit $rc, $(cat "$scratch/firefox.log" 2>&1)"
  grep -q "unknown webapp: $name" "$scratch/stderr" || die "'$name' is not named in the refusal: $(cat "$scratch/stderr")"
done
log "ok: anything but the name of a webapp directory is refused"
