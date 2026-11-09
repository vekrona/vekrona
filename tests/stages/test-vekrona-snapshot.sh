#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"
SCRIPT="$ROOT/bin/vekrona-snapshot"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
export WORK="$work" PATH="$work/bin:$PATH" VEKRONA_SNAPSHOTS_DIR="$work/snapshots"

# sudo runs its command. snapper keeps one line per call in snapper.calls, answers list from the file `listing` (number,date lines;
# the number-only listing is its first column), takes a snapshot as number 42, and deletes the directories of the snapshots it is asked
# to delete, as the real one does. btrfs deletes the directory of a subvolume and records the call.
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
write_fake "$work/bin/snapper" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$WORK/snapper.calls"
args=("$@")
command="" columns=""
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    list | delete | create) [[ -n "$command" ]] || command="${args[i]}" ;;
    --columns) columns="${args[i + 1]}" ;;
  esac
done
case "$command" in
  list) if [[ "$columns" == number,date ]]; then cat "$WORK/listing"; else cut -d, -f1 "$WORK/listing"; fi ;;
  delete) for n in "${args[@]}"; do [[ ! "$n" =~ ^[0-9]+$ ]] || rm -rf "$VEKRONA_SNAPSHOTS_DIR/$n"; done ;;
  create) echo 42 ;;
esac
F
write_fake "$work/bin/btrfs" <<'F'
#!/usr/bin/env bash
echo "btrfs $*" >>"$WORK/btrfs.calls"
rm -rf "${*: -1}"
F

iso_days_ago() { date -d "$1 days ago" '+%Y-%m-%d %H:%M:%S'; }
snapper_calls() { cat "$work/snapper.calls"; }

# Runs the tool and leaves its output in $out and its exit status in $status.
run() {
  : >"$work/snapper.calls"
  : >"$work/btrfs.calls"
  status=0
  out="$("$SCRIPT" "$@" 2>&1)" || status=$?
}
refused() {
  run "$@"
  [[ "$status" -eq 2 ]] || die "'$*' was not refused with exit 2, got $status: $out"
  [[ "$out" == *usage* ]] || die "'$*' was refused without the usage: $out"
  [[ ! -s "$work/snapper.calls" && ! -s "$work/btrfs.calls" ]] || die "'$*' was refused but ran snapper or btrfs: $(snapper_calls)"
}

printf '%s\n' "0," "1,$(iso_days_ago 10)" "2,$(iso_days_ago 8)" "3,$(iso_days_ago 6)" "4,$(iso_days_ago 0)" >"$work/listing"

run --help
[[ "$status" -eq 0 && "$out" == *"vekrona-snapshot create"* ]] || die "--help did not print the usage and exit 0: $status $out"
[[ ! -s "$work/snapper.calls" ]] || die "--help ran snapper: $(snapper_calls)"
run -h
[[ "$status" -eq 0 ]] || die "-h did not exit 0: $status $out"
log "ok: --help and -h print the usage, exit 0 and create nothing"

for args in "" "lizard" "--lizard" "--help extra" "list extra" "create" "create -x" "create --help" "create a b" "prune" "prune lizard" "prune --all extra" \
  "prune --older-than" "prune --older-than 7d extra"; do
  # shellcheck disable=SC2086 # the words of args are the arguments
  refused $args
done
refused create ""
refused ""
log "ok: no subcommand, an unknown one, a flag as description, a missing or empty description and surplus arguments are refused with the usage before snapper runs"

run create "before the upgrade"
[[ "$status" -eq 0 && "$out" == 42 ]] || die "create did not print the number of the snapshot: $status $out"
[[ "$(snapper_calls)" == "-c root create -p -c number -d before the upgrade" ]] || die "create called snapper with: $(snapper_calls)"
log "ok: create takes a numbered snapshot with the description as one argument"

run list
[[ "$status" -eq 0 && "$(snapper_calls)" == "-c root list" ]] || die "list called snapper with: $(snapper_calls)"
log "ok: list lists the snapshots"

run prune --older-than 7d
[[ "$status" -eq 0 && "$(snapper_calls | tail -n 1)" == "-c root delete --sync 1 2" ]] || die "prune --older-than 7d did not delete exactly 1 and 2: $status $(snapper_calls)"
run prune --older-than 1d
[[ "$status" -eq 0 && "$(snapper_calls | tail -n 1)" == "-c root delete --sync 1 2 3" ]] || die "prune --older-than 1d did not delete exactly 1, 2 and 3: $status $(snapper_calls)"
run prune --older-than 99999d
[[ "$status" -eq 0 && "$(snapper_calls | grep -c delete || true)" -eq 0 ]] || die "a cutoff before every snapshot still deleted some: $(snapper_calls)"
log "ok: prune --older-than deletes exactly the snapshots dated before the cutoff, in one call, and never snapshot 0"

for days in 0d -1d 7 d lizard 7D 07d 1.5d 7dd ""; do
  refused prune --older-than "$days"
done
log "ok: an age that is not a positive whole number of days is refused before snapper runs"

printf '%s\n' "0," "1,lizard" >"$work/listing"
run prune --older-than 7d
[[ "$status" -ne 0 && "$out" == *"lizard"* ]] || die "a date snapper printed in another format was not reported: $status $out"
if grep -q delete "$work/snapper.calls"; then die "snapshots were deleted by a date that could not be read"; fi
log "ok: a date that is not YYYY-MM-DD HH:MM:SS stops the prune instead of guessing"

printf '%s\n' "0," "1,$(iso_days_ago 10)" "2,$(iso_days_ago 8)" >"$work/listing"
mkdir -p "$VEKRONA_SNAPSHOTS_DIR"/{1,2,10,x}/snapshot
run prune --all
[[ "$status" -eq 0 && "$(snapper_calls | tail -n 1)" == "-c root delete --sync 1 2" ]] || die "prune --all did not delete exactly the listed snapshots 1 and 2: $status $(snapper_calls)"
[[ "$(<"$work/btrfs.calls")" == "btrfs subvolume delete --commit-after $VEKRONA_SNAPSHOTS_DIR/10/snapshot" ]] || die "prune --all did not delete exactly the orphan: $(<"$work/btrfs.calls")"
[[ ! -e "$VEKRONA_SNAPSHOTS_DIR/10" ]] || die "the directory of the orphan was left"
[[ -d "$VEKRONA_SNAPSHOTS_DIR/x/snapshot" ]] || die "a path that is not <number>/snapshot was deleted"
log "ok: prune --all deletes every listed snapshot and the subvolume snapper does not list, and nothing outside <number>/snapshot"

printf '%s\n' "0," >"$work/listing"
rm -rf "$VEKRONA_SNAPSHOTS_DIR"
mkdir "$VEKRONA_SNAPSHOTS_DIR"
run prune --all
[[ "$status" -eq 0 && ! -s "$work/btrfs.calls" ]] || die "prune --all with nothing to delete failed or deleted something: $status $out"
if grep -q delete "$work/snapper.calls"; then die "snapper was asked to delete with no snapshot listed: $(snapper_calls)"; fi
log "ok: prune --all with only snapshot 0 deletes nothing"
