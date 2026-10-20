#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/stores"
export WORK="$work" VEKRONA_YES=1
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
# dnf's review prints $REVIEW_OUT and exits $REVIEW_STATUS; its replay logs itself and exits $REPLAY_STATUS.
write_fake "$work/bin/dnf" <<'F'
#!/usr/bin/env bash
if [[ "$1" == replay ]]; then echo replay >>"$WORK/calls"; exit "${REPLAY_STATUS:-0}"; fi
echo review >>"$WORK/calls"
printf '%s\n' "${REVIEW_OUT-Removing: foo}"
exit "${REVIEW_STATUS:-0}"
F
PATH="$work/bin:$PATH"

# What a stage does with the result: it acts only when something was applied, and says so when there was nothing to do.
outcome() {
  rm -f "$work/calls"
  rc=0
  (if run_reviewed "$work/stores" protected "the removal" remove foo; then echo applied; else echo nothing; fi) >"$work/out" 2>&1 || rc=$?
}

outcome
[[ "$rc" == 0 && "$(tail -1 "$work/out")" == applied && "$(<"$work/calls")" == $'review\nreplay' ]] || die "a reviewed transaction must be replayed and reported as applied: exit $rc, $(cat "$work/out")"
log "ok: a reviewed transaction is replayed"

REVIEW_OUT="Nothing to do." outcome
[[ "$rc" == 0 && "$(tail -1 "$work/out")" == nothing && "$(<"$work/calls")" == review ]] || die "a review with nothing to do must replay nothing and return 1: exit $rc, $(cat "$work/out")"
log "ok: nothing to do replays nothing and says so"

REPLAY_STATUS=1 outcome
[[ "$rc" != 0 ]] && grep -q 'dnf replay of the removal failed' "$work/out" && ! grep -qxE 'applied|nothing' "$work/out" \
  || die "a failed replay must end the command, not read as applied or as nothing to do: exit $rc, $(cat "$work/out")"
log "ok: a failed replay ends the command"
