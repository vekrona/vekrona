#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

# systemctl stub for the user manager. list-units prints $LISTING once daemon-reload has run (the generators rerun then and the
# removed desktop entries turn their units not-found) and $STALE_LISTING before (the units still read loaded); LIST_FAIL and
# RELOAD_FAIL make the lister and the reload fail, AFTER_KILL_LISTING replaces $LISTING from the second listing of a run on (the killed
# unit is failed by then), RESET_FAIL makes reset-failed fail. The user manager's ControlGroup is the one in
# $CGROUP_PATH; stop and kill fail like the host's user manager did for an orphan it held as not loaded (exit 5).
write_fake "$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
case "$*" in
  "--user daemon-reload") [[ -z "${RELOAD_FAIL-}" ]] || exit 1; touch "$RELOADED" ;;
  "--user list-units "*)
    [[ -z "${LIST_FAIL-}" ]] || exit 1
    if [[ ! -e "$RELOADED" ]]; then cat "$STALE_LISTING"
    elif [[ -n "${AFTER_KILL_LISTING-}" && -e "$LISTED" ]]; then cat "$AFTER_KILL_LISTING"
    else cat "$LISTING"; touch "$LISTED"; fi ;;
  "--user reset-failed "*) [[ -z "${RESET_FAIL-}" ]] || exit 1 ;;
  "show -p ControlGroup --value user@"*) echo "$CGROUP_PATH" ;;
  "--user stop "* | "--user kill "*) echo "Failed to $2 unit ${*: -1}: Unit ${*: -1} not loaded." >&2; exit 5 ;;
  *) exit 2 ;;
esac
FAKE
# inotifywait stub: reports a timeout (status 2), after the pending change of the watched cgroup.events (its last argument): FLIP_ON_WAIT
# empties its cgroup, REMOVE_ON_WAIT removes the cgroup directory, as systemd does, and fails like inotifywait on a missing file.
write_fake "$work/bin/inotifywait" <<'FAKE'
#!/usr/bin/env bash
echo "inotifywait $*" >> "$STUB_LOG"
if [[ -n "${FLIP_ON_WAIT-}" ]]; then printf 'populated 0\nfrozen 0\n' > "${!#}"; exit 0; fi
if [[ -n "${REMOVE_ON_WAIT-}" ]]; then rm -r "$(dirname "${!#}")"; exit 1; fi
exit 2
FAKE
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" LISTING="$work/listing" STALE_LISTING="$work/stale-listing" RELOADED="$work/reloaded" LISTED="$work/listed"
export VEKRONA_SYSFS_ROOT="$work/root"
export CGROUP_PATH=/user.slice/user-1000.slice/user@1000.service
manager="$VEKRONA_SYSFS_ROOT/sys/fs/cgroup$CGROUP_PATH"
: > "$STUB_LOG"

# unit SLICE NAME POPULATED: a unit cgroup holding this test's own shell (its command line is logged) and a pid that is gone.
unit_cgroup() {
  local dir="$manager/$1/$2"
  mkdir -p "$dir"
  printf '%s\n999999999\n' "$$" > "$dir/cgroup.procs"
  printf 'populated %s\nfrozen 0\n' "$3" > "$dir/cgroup.events"
  : > "$dir/cgroup.kill"
}
killed() { [[ "$(<"$manager/$1/$2/cgroup.kill")" == 1 ]]; }

cat > "$LISTING" <<'LIST'
app-blueman@autostart.service                                    not-found active   running app-blueman@autostart.service
app-com.onepassword.OnePassword@autostart.service                loaded    active   running 1Password
app-nm\x2dapplet@autostart.service                               not-found active   running app-nm\x2dapplet@autostart.service
app-gnome\x2dkeyring\x2dssh@autostart.service                    loaded    inactive dead    SSH Key Agent
app-vboxclient@autostart.service                                 not-found inactive dead    app-vboxclient@autostart.service
app-sealertauto@autostart.service                                not-found failed   failed  app-sealertauto@autostart.service
app-geoclue\x2ddemo@autostart.service                            loaded    failed   failed  Geoclue Demo agent
LIST
# What the manager still shows after network-manager-applet is removed without any user unit file going with it: its unit is
# loaded until something reloads the manager. Each case below that starts without $RELOADED proves the reload.
sed 's/ not-found / loaded    /' "$LISTING" > "$STALE_LISTING"

declare -a orphans
read_gone_autostart_units orphans active
[[ "$(printf '%s\n' "${orphans[@]}")" == $'app-blueman@autostart.service\napp-nm\\x2dapplet@autostart.service' ]] ||
  die "read_gone_autostart_units did not list exactly the not-found active units: ${orphans[*]}"
log "ok: only a not-found unit that is active is an orphan, read after the user manager reloaded"
declare -a failed_units
read_gone_autostart_units failed_units failed
[[ "${failed_units[*]}" == app-sealertauto@autostart.service ]] ||
  die "read_gone_autostart_units did not list exactly the not-found failed units: ${failed_units[*]}"
log "ok: a failed unit whose desktop entry still exists is not listed as gone"

BLUEMAN='app-blueman@autostart.service'
NM='app-nm\x2dapplet@autostart.service'
unit_cgroup app.slice "$BLUEMAN" 0
unit_cgroup app.slice "$NM" 0
unit_cgroup app.slice 'app-com.onepassword.OnePassword@autostart.service' 1

rm "$RELOADED"
stop_orphaned_autostart_units 2>"$work/err"
killed app.slice "$BLUEMAN" || die "the cgroup of $BLUEMAN was not killed"
killed app.slice "$NM" || die "the cgroup of $NM was not killed"
[[ -z "$(<"$manager/app.slice/app-com.onepassword.OnePassword@autostart.service/cgroup.kill")" ]] || die "a unit that is not an orphan was killed"
log "ok: every orphan's cgroup is killed and nothing else, although systemctl refuses to stop or kill an orphan"
[[ "$(grep -c 'reset-failed' "$STUB_LOG")" == 1 ]] || die "the failed state must be reset once: $(<"$STUB_LOG")"
grep -qxF 'systemctl --user reset-failed app-sealertauto@autostart.service app-blueman@autostart.service app-nm\x2dapplet@autostart.service' "$STUB_LOG" ||
  die "reset-failed must name the failed gone unit and the killed orphans, and no other: $(grep reset-failed "$STUB_LOG")"
log "ok: the units killed now and the ones an earlier run left failed are reset by name"

grep -q "killing pid $$: " "$work/err" || die "the command line of an orphan's process was not logged: $(<"$work/err")"
grep -q 'pid 999999999 already exited' "$work/err" || die "a process that is gone was not reported: $(<"$work/err")"
log "ok: the processes of an orphan are logged before the kill"

unit_cgroup background.slice "$BLUEMAN" 0
if (stop_orphaned_autostart_units) 2>"$work/err"; then die "an orphan with two cgroups was accepted"; fi
grep -qF "expected one cgroup named $BLUEMAN under $manager, found 2" "$work/err" || die "an ambiguous cgroup did not say so: $(<"$work/err")"
rm -r "$manager/background.slice"
log "ok: an orphan with two cgroups is an error"

rm -r "$manager/app.slice/$NM"
if (stop_orphaned_autostart_units) 2>"$work/err"; then die "an orphan without a cgroup was accepted"; fi
grep -qF "expected one cgroup named $NM under $manager, found 0" "$work/err" || die "a missing cgroup did not say so: $(<"$work/err")"
[[ "$(tail -n 1 "$work/err")" == *"expected one cgroup named $NM under $manager, found 0" ]] || die "the stage did not end on the missing cgroup: $(<"$work/err")"
unit_cgroup app.slice "$NM" 0
log "ok: an orphan without a cgroup is an error, and ends the stage"

kill_cgroup "$work/vanished" 2>"$work/err" || die "a cgroup directory that was already gone was not taken for killed"
grep -qF "$work/vanished is already gone" "$work/err" || die "a vanished cgroup directory was not reported: $(<"$work/err")"
log "ok: a cgroup directory that vanished before the kill counts as killed"

mkdir "$work/broken"
mkdir "$work/broken/cgroup.procs"
if (kill_cgroup "$work/broken") 2>"$work/err"; then die "an unreadable cgroup.procs was accepted"; fi
grep -qF "cannot read $work/broken/cgroup.procs: cat: $work/broken/cgroup.procs: Is a directory" "$work/err" || die "an unreadable cgroup.procs did not say why: $(<"$work/err")"
rmdir "$work/broken/cgroup.procs"
: > "$work/broken/cgroup.procs"
mkdir "$work/broken/cgroup.kill"
if (kill_cgroup "$work/broken") 2>"$work/err"; then die "an unwritable cgroup.kill was accepted"; fi
grep -qF "cannot write $work/broken/cgroup.kill: " "$work/err" || die "an unwritable cgroup.kill did not say so: $(<"$work/err")"
grep -q 'Is a directory' "$work/err" || die "an unwritable cgroup.kill did not say why: $(<"$work/err")"
log "ok: a cgroup directory that is there but cannot be read or killed is an error with its cause"

if (CGROUP_PATH='' stop_orphaned_autostart_units) 2>"$work/err"; then die "a user manager without a cgroup was accepted"; fi
grep -q 'has no cgroup' "$work/err" || die "a user manager without a cgroup did not say so: $(<"$work/err")"
log "ok: a user manager without a cgroup is an error"

unit_cgroup app.slice "$NM" 1
if (CGROUP_EMPTY_TIMEOUT_SEC=1 stop_orphaned_autostart_units) 2>"$work/err"; then die "a cgroup that never emptied was accepted"; fi
grep -q 'survived cgroup.kill' "$work/err" || die "a cgroup that never emptied did not say so: $(<"$work/err")"
log "ok: a cgroup that does not empty is an error"

: > "$STUB_LOG"
(FLIP_ON_WAIT=1 stop_orphaned_autostart_units) 2>/dev/null
grep -q '^inotifywait .*cgroup.events$' "$STUB_LOG" || die "the wait did not watch cgroup.events: $(<"$STUB_LOG")"
grep -qx 'populated 0' "$manager/app.slice/$NM/cgroup.events" || die "the flip stub did not run"
log "ok: the wait returns once cgroup.events says populated 0"

unit_cgroup app.slice "$NM" 1
(REMOVE_ON_WAIT=1 stop_orphaned_autostart_units) 2>/dev/null || die "a cgroup that systemd removed was not taken for empty"
[[ ! -e "$manager/app.slice/$NM" ]] || die "the remove stub did not run"
unit_cgroup app.slice "$NM" 0
log "ok: a cgroup that is gone counts as empty"

if (VEKRONA_SYSFS_ROOT="$work/none" stop_orphaned_autostart_units) 2>"$work/err"; then die "a user manager without a cgroup tree was accepted"; fi
grep -q "found 0" "$work/err" || die "a missing cgroup tree did not say so: $(<"$work/err")"
log "ok: a missing cgroup tree is an error"

: > "$STUB_LOG"
: > "$LISTING"
stop_orphaned_autostart_units 2>/dev/null
! grep -q 'ControlGroup' "$STUB_LOG" || die "the cgroups were read with no orphan: $(<"$STUB_LOG")"
! grep -q 'reset-failed' "$STUB_LOG" || die "reset-failed with no unit would reset every failed unit of the manager: $(<"$STUB_LOG")"
log "ok: without an orphan nothing is read or killed, and the failed state of no unit is reset"

printf 'app-sealertauto@autostart.service not-found failed failed app-sealertauto@autostart.service\n' > "$LISTING"
: > "$STUB_LOG"
stop_orphaned_autostart_units 2>/dev/null
! grep -q 'ControlGroup' "$STUB_LOG" || die "the cgroups were read with no orphan: $(<"$STUB_LOG")"
grep -qxF 'systemctl --user reset-failed app-sealertauto@autostart.service' "$STUB_LOG" || die "a failed unit without an orphan was not reset: $(<"$STUB_LOG")"
log "ok: a unit that an earlier run left failed is reset although no orphan runs"
if (RESET_FAIL=1 stop_orphaned_autostart_units) 2>"$work/err"; then die "stage 30 went on while reset-failed failed"; fi
grep -q 'cannot reset the failed state of app-sealertauto@autostart.service' "$work/err" || die "a failing reset-failed did not say so: $(<"$work/err")"
log "ok: a failing reset-failed is an error"

# systemd lists a killed orphan as failed once its process is gone: the unit is then both an orphan and a failed gone unit, and the
# second name in a reset-failed would find the first one's unit unloaded and fail.
printf 'app-blueman@autostart.service not-found active running app-blueman@autostart.service\n' > "$LISTING"
printf 'app-blueman@autostart.service not-found failed failed app-blueman@autostart.service\n' > "$work/after-kill-listing"
rm -f "$LISTED"
: > "$STUB_LOG"
AFTER_KILL_LISTING="$work/after-kill-listing" stop_orphaned_autostart_units 2>/dev/null
grep -qxF 'systemctl --user reset-failed app-blueman@autostart.service' "$STUB_LOG" || die "a killed orphan that reads as failed was not reset exactly once: $(grep reset-failed "$STUB_LOG")"
log "ok: an orphan that the listing shows as failed after the kill is reset once"
: > "$LISTING"

# Stage 70 calls the check inside `if`, where set -e is off: a reload or lister failure must still end the run, not read as "no orphans".
for failure in RELOAD_FAIL:"cannot reload the user manager" LIST_FAIL:"cannot list the user's autostart units"; do
  variable="${failure%%:*}" message="${failure#*:}"
  if (export "$variable=1"; stop_orphaned_autostart_units) 2>"$work/err"; then die "stage 30 went on while $variable"; fi
  grep -q "$message" "$work/err" || die "stage 30 did not report $variable: $(<"$work/err")"
  if (export "$variable=1"; no_orphaned_autostart_units) 2>"$work/err"; then die "stage 70's check passed while $variable"; fi
  grep -q "$message" "$work/err" || die "stage 70's check did not report $variable: $(<"$work/err")"
done
log "ok: a failing reload or lister is an error in both stages, even inside an if"

: > "$LISTING"
no_orphaned_autostart_units || die "the check failed with no unit listed"
cat > "$LISTING" <<'LIST'
app-blueman@autostart.service not-found active running app-blueman@autostart.service
LIST
if no_orphaned_autostart_units 2>/dev/null; then die "the check passed with an orphan running"; fi
rm "$RELOADED"
if no_orphaned_autostart_units 2>/dev/null; then die "the check passed with an orphan running behind a stale listing"; fi
log "ok: the check passes without an orphan and fails with one, also when only the reload reveals it"
