#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
VEKRONA_UPDATE_LOCK="$scratch/lock"
mkfifo "$scratch/held" "$scratch/release" "$scratch/waiting"

# A holder that says it holds the lock and keeps it until it is told to let go.
flock "$VEKRONA_UPDATE_LOCK" bash -c 'echo held >"$1"; read -r _ <"$2"' _ "$scratch/held" "$scratch/release" &
holder=$!
read -r _ <"$scratch/held"

# The step under test: it logs that it waits, and writes a marker once it holds the lock.
(update_lock 2>"$scratch/waiting" && touch "$scratch/acquired") &
waiter=$!
read -r waiting <"$scratch/waiting"
[[ "$waiting" == *"another update step holds $VEKRONA_UPDATE_LOCK, waiting for it" ]] || die "the waiting step did not say it waits: $waiting"
[[ ! -e "$scratch/acquired" ]] || die "the lock was taken while another step held it"
log "ok: a step waits while another holds the update lock"

echo go >"$scratch/release"
wait "$holder"
wait "$waiter"
[[ -e "$scratch/acquired" ]] || die "the lock was not taken once the holder let go"
log "ok: the waiting step proceeds once the holder lets go"
