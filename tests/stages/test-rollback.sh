#!/usr/bin/env bash
# shellcheck disable=SC2016 # the stub bodies are written to files literally and expand when the stub runs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
unshare -r true || die "cannot create a user namespace to stand in for root"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
mkdir -p "$stubs"
stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }

# The btrfs top level is a directory: "mounting" it copies $TOP into the mount point, "unmounting" copies the mount point
# back to $TOP, so the test reads what the rollback left. Subvolume commands are cp and rm.
stub findmnt 'echo /dev/fake'
stub mount 'cp -a "$TOP/." "${*: -1}"'
stub umount 'rm -rf "$TOP"; mkdir "$TOP"; cp -a "$1/." "$TOP"; rm -rf "$1"/* "$1"/.[!.]*'
stub mountpoint 'exit 0'
stub btrfs 'case "$2" in snapshot) cp -a "$3" "$4" ;; delete) rm -rf "$3" ;; *) exit 99 ;; esac'
# FAIL_MV_TO names the destination whose rename fails, once.
stub mv 'if [[ -n "${FAIL_MV_TO:-}" && "${*: -1}" == *"/$FAIL_MV_TO" && ! -e "$FAIL_MV_DONE" ]]; then touch "$FAIL_MV_DONE"; echo "mv: injected failure" >&2; exit 1; fi
exec /usr/bin/mv "$@"'
export PATH="$stubs:$PATH" TOP="$scratch/top" FAIL_MV_DONE="$scratch/mv-failed"

fresh_top() {
  rm -rf "$TOP" "$FAIL_MV_DONE"
  mkdir -p "$TOP/root/.snapshots/5/snapshot/etc" "$TOP/root/.snapshots/5/snapshot/.snapshots" "$TOP/root/etc"
  echo "/nix btrfs" > "$TOP/root/.snapshots/5/snapshot/etc/fstab"
  echo old > "$TOP/root/.snapshots/5/snapshot/etc/state"
  echo new > "$TOP/root/etc/state"
}
rollback() { unshare -r "$ROOT/bin/vekrona-rollback" --yes "$@" 2>"$scratch/stderr"; }
state_of() { cat "$TOP/$1/etc/state"; }
old_roots() { compgen -G "$TOP/root.old-*" || true; }

fresh_top
rollback 5 >/dev/null || die "a rollback of a healthy snapshot failed: $(cat "$scratch/stderr")"
[[ "$(state_of root)" == old ]] || die "root does not hold the snapshot's files"
[[ -d "$TOP/root/.snapshots/5/snapshot" ]] || die ".snapshots did not move to the restored root"
[[ "$(state_of "$(basename "$(old_roots)")")" == new ]] || die "the previous root was not kept as root.old-*"
[[ ! -e "$TOP/root.vekrona-new" ]] || die "the scratch snapshot is left behind"
log "ok: a rollback restores the snapshot as root, keeps the previous root and moves .snapshots over"

fresh_top
mkdir "$TOP/root/.snapshots/5/snapshot/.snapshots/stray"
if rollback 5 >/dev/null; then die "a snapshot holding a non-empty .snapshots was accepted"; fi
[[ "$(state_of root)" == new && -d "$TOP/root/.snapshots/5" ]] || die "the failure touched the current root"
[[ -z "$(old_roots)" && ! -e "$TOP/root.vekrona-new" ]] || die "the failure left a renamed root or a scratch snapshot: $(ls -A "$TOP")"
log "ok: a snapshot that cannot take over .snapshots is refused before anything is renamed"

for failing in root .snapshots; do
  fresh_top
  FAIL_MV_TO="$failing" rollback 5 >/dev/null && die "a failing rename of $failing was accepted"
  grep -q 'the current root is back in place' "$scratch/stderr" || die "the failure ($failing) did not say the root is back: $(cat "$scratch/stderr")"
  [[ "$(state_of root)" == new && -d "$TOP/root/.snapshots/5" ]] || die "the current root is not back after a failing rename of $failing: $(ls -A "$TOP")"
  [[ -z "$(old_roots)" && ! -e "$TOP/root.vekrona-new" ]] || die "leftovers after a failing rename of $failing: $(ls -A "$TOP")"
  log "ok: a failing rename of $failing puts the current root back and leaves nothing behind"
done
