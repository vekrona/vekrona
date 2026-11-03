#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"

scratch="$(mktemp -d)"
VEKRONA_UPDATE_LOCK="$scratch/lock"
mkfifo "$scratch/held" "$scratch/release" "$scratch/waiting"
# A failed check must not leave a holder (and a waiter queued behind it) blocked for ever, keeping the runner's output open: a
# read-write open of the fifo never blocks, and the line lets a holder that still waits go.
trap '{ echo go >&3; } 3<>"$scratch/release"; rm -rf "$scratch"' EXIT

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

# A holder that never lets go must not block every later step for ever: the waiter gives up after UPDATE_LOCK_WAIT_SECONDS and
# says which lock it waited for.
flock "$VEKRONA_UPDATE_LOCK" bash -c 'echo held >"$1"; read -r _ <"$2"' _ "$scratch/held" "$scratch/release" &
holder=$!
read -r _ <"$scratch/held"

# timeout 60 only turns a missing bound into a failure of this test instead of a hang: the bound under test is 1 s.
out="$(UPDATE_LOCK_WAIT_SECONDS=1 VEKRONA_UPDATE_LOCK="$VEKRONA_UPDATE_LOCK" timeout 60 bash -c 'source "$1/tests/lib.sh"; update_lock' _ "$REPO" 2>&1)" && die "update_lock took the lock while it was held"
[[ "$out" == *"timed out after 1 s waiting for the update lock $VEKRONA_UPDATE_LOCK"* ]] || die "the timeout does not name the lock: $out"
log "ok: a step gives up with a message naming the lock when its holder never lets go"

echo go >"$scratch/release"
wait "$holder"
