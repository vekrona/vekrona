#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
MARKER="$VEKRONA_STATE_DIR/offline-pending"

apply() { run_as_root "$REPO/libexec/vekrona-update-apply" "$@" 2>"$work/err"; }
reset() {
  rm -f "$MARKER" "$VEKRONA_STATE_DIR"/updates.json
  echo 0 >"$work/dnf.rc"; echo 0 >"$work/upgrade.rc"
  # What the 1Password RPM's %post leaves behind.
  sed 's/^repo_gpgcheck=1/repo_gpgcheck=0/' "$REPO/etc/yum.repos.d/1password.repo" >"$work/repos/1password.repo"
  : >"$FAKE_LOG"
}
# True when the log has these lines in this order (other lines may lie between them).
in_order() {
  local from=1 pattern line
  for pattern in "$@"; do
    line="$(tail -n "+$from" "$FAKE_LOG" | grep -n -m1 -- "$pattern" | cut -d: -f1)" || die "'$pattern' is missing or out of order in: $(cat "$FAKE_LOG")"
    from=$((from + line))
  done
}
absent() { if grep -q -- "$1" "$FAKE_LOG"; then die "unexpected '$1' in: $(cat "$FAKE_LOG")"; fi; }

reset
apply --online
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^dnf5 upgrade --refresh -y$' '^flatpak update --system -y --noninteractive$' \
  '^mise upgrade --dry-run$' '^mise upgrade$' '^mise prune' '^mise reshim$' '^snapper .*--pre-number 10' '^dnf5 check-upgrade --refresh --json$'
absent 'offline'
absent 'without the update lock'
cmp -s "$work/repos/1password.repo" "$REPO/etc/yum.repos.d/1password.repo" || die "the 1Password repo file was not repaired after dnf"
[[ -f "$VEKRONA_STATE_DIR/updates.json" ]] || die "the online run did not rewrite updates.json"
[[ ! -e "$MARKER" ]] || die "an online run left the offline marker"
log "ok: --online runs the steps in order under the lock, repairs the 1Password repo file and rewrites updates.json"

reset; echo 1 >"$work/upgrade.rc"
if apply --online; then die "a failing dnf upgrade was accepted"; fi
in_order '^dnf5 upgrade' '^snapper .*--pre-number 10'
absent '^flatpak update'
log "ok: a failing dnf stops the run, and the snapshot pair is still closed"

reset; echo 100 >"$work/dnf.rc"
apply --offline
in_order '^vekrona-proton stage$' '^snapper .*create .*vekrona-update pre' '^flatpak update' '^mise upgrade$' '^dnf5 check-upgrade --refresh$' \
  '^dnf5 upgrade --offline -y$' '^snapper .*--pre-number 10' '^dnf5 offline reboot -y$'
absent '^dnf5 upgrade --refresh'
[[ -s "$MARKER" ]] || die "the offline marker was not written before the reboot"
log "ok: --offline updates Flatpak and mise first, stores dnf's transaction, closes the snapshot pair, writes the marker and reboots"

reset; echo 100 >"$work/dnf.rc"
apply --offline --poweroff
in_order '^dnf5 offline reboot -y --poweroff$'
log "ok: --offline --poweroff powers off after the update"

reset
apply --offline
in_order '^flatpak update' '^mise upgrade$' '^dnf5 check-upgrade --refresh$' '^dnf5 check-upgrade --refresh --json$'
absent 'dnf5 upgrade'
absent 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written with no transaction stored"
log "ok: with nothing for dnf, Flatpak and mise run and the machine does not reboot"

reset; echo 7 >"$work/dnf.rc"
if apply --offline; then die "a failing dnf check-upgrade was accepted"; fi
absent 'offline reboot'
[[ ! -e "$MARKER" ]] || die "a marker was written after a failed check-upgrade"
log "ok: a dnf failure before the transaction is stored fails the run without a reboot"

for args in "" "--poweroff" "--online --poweroff" "--offline --online" "--sideways"; do
  # shellcheck disable=SC2086
  if apply $args; then die "accepted the arguments '$args'"; fi
  grep -q '^usage:' "$work/err" || die "no usage for '$args': $(cat "$work/err")"
done
log "ok: unknown or mixed arguments print the usage"

if "$REPO/libexec/vekrona-update-apply" --online 2>"$work/err"; then die "ran as a regular user"; fi
grep -q 'must run as root' "$work/err" || die "no root requirement error: $(cat "$work/err")"
log "ok: a regular user is refused"
