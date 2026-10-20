#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
cp "$work/assumeno.out" "$work/assumeno.default.out"
JSON="$VEKRONA_STATE_DIR/updates.json"

check() { run_as_root "$REPO/libexec/vekrona-update-check" 2>"$work/err"; }
reset() {
  rm -f "$JSON" "$VEKRONA_STATE_DIR/update-skip" "$work"/units/* "$work/proton.fails" "$work/reported"
  echo '{}' >"$work/dnf.json"; echo 0 >"$work/dnf.rc"
  : >"$work/flatpak.tsv"; : >"$work/installed.tsv"
  : >"$FAKE_LOG"
  cp "$work/assumeno.default.out" "$work/assumeno.out"; echo 1 >"$work/assumeno.rc"
}
field() { jq -c "$1" "$JSON"; }
night_timer_active() { [[ -e "$work/units/vekrona-update-night.timer.active" ]]; }

updates() {
  cat >"$work/dnf.json" <<'F'
{"upgrades": [
  {"name": "kernel", "arch": "x86_64", "evr": "6.17.2-200.fc44", "repository": "updates"},
  {"name": "SDL3", "arch": "i686", "evr": "3.4.18-1.fc44", "repository": "updates"},
  {"name": "SDL3", "arch": "x86_64", "evr": "3.4.18-1.fc44", "repository": "updates"},
  {"name": "claude-code", "arch": "x86_64", "evr": "2.1.3-1", "repository": "claude-code"},
  {"name": "proton-mail", "arch": "x86_64", "evr": "1.15.0-1", "repository": "vekrona-proton"},
  {"name": "tzdata", "arch": "noarch", "evr": "1:2026b-1.fc44", "repository": "updates"}
]}
F
  echo 100 >"$work/dnf.rc"
  printf '%s\t%s\n' kernel.x86_64 6.17.1-200.fc44 kernel.x86_64 6.17.0-200.fc44 SDL3.x86_64 3.4.17-1.fc44 \
    claude-code.x86_64 2.1.0-1 proton-mail.x86_64 1.14.0-1 tzdata.noarch 1:2026a-1.fc44 >"$work/installed.tsv"
  printf 'org.signal.Signal\t7.1\ndev.zed.Zed\t\n' >"$work/flatpak.tsv"
}

reset; updates
check
want='[{"name":"System packages","items":[{"name":"SDL3","from":"3.4.17-1.fc44","to":"3.4.18-1.fc44"},{"name":"claude-code","from":"2.1.0-1","to":"2.1.3-1"},{"name":"kernel","from":"6.17.1-200.fc44","to":"6.17.2-200.fc44"},{"name":"tzdata","from":"1:2026a-1.fc44","to":"1:2026b-1.fc44"}]},
{"name":"Flatpak","items":[{"name":"org.signal.Signal","from":"","to":"7.1"},{"name":"dev.zed.Zed","from":"","to":""}]},
{"name":"Proton","items":[{"name":"proton-mail","from":"1.14.0-1","to":"1.15.0-1"}]}]'
[[ "$(field .groups)" == "$(jq -c . <<<"$want")" ]] || die "wrong groups: $(field .groups)"
log "ok: updates.json groups dnf, Flatpak and Proton updates, newest installed version as 'from'"

[[ "$(field '{pending, night_armed}')" == '{"pending":true,"night_armed":true}' ]] || die "wrong flags: $(field .)"
[[ "$(field '.checked | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+$")')" == true ]] || die "checked is not an ISO timestamp: $(field .checked)"
[[ "$(stat -c %a "$JSON")" == 644 ]] || die "updates.json mode is $(stat -c %a "$JSON")"
[[ -z "$(ls -A "$VEKRONA_STATE_DIR" | grep -v '^updates.json$')" ]] || die "left files behind: $(ls -A "$VEKRONA_STATE_DIR")"
night_timer_active || die "pending updates did not arm the night timer"
[[ "$(sed -n 1p "$FAKE_LOG")" == "vekrona-proton stage" ]] || die "the Proton repo was not staged first: $(cat "$FAKE_LOG")"
log "ok: pending is true, the night timer is armed, the file is world-readable, whole, and Proton was staged first"

# A Proton feed that cannot be read must not stop the check for everything else, and must still be told to the user.
printf '#!/bin/sh\necho "$*" >> "%s/reported"\n' "$work" > "$work/reporter"
chmod +x "$work/reporter"
reset; updates; touch "$work/proton.fails"
VEKRONA_ERROR_REPORTER="$work/reporter" check || die "a failing Proton stage stopped the check: $(cat "$work/err")"
[[ "$(field '.groups | map(.name) | join(",")')" == '"System packages,Flatpak,Proton"' ]] || die "the other groups are missing: $(field .groups)"
[[ "$(wc -l < "$work/reported")" == 1 ]] || die "the Proton failure must be reported once: $(cat "$work/reported" 2>&1)"
grep -q 'Proton packages were not updated.*cannot read Proton feed' "$work/reported" || die "the report lacks the cause: $(cat "$work/reported")"
log "ok: a Proton stage that fails is reported once, with its cause, and the check goes on"

reset
check
[[ "$(field .)" == "$(jq -c '{checked, pending: false, night_armed: false, groups: []}' "$JSON")" ]] || die "nothing pending: $(field .)"
night_timer_active && die "the night timer is armed with nothing pending"
log "ok: with nothing pending the file says so and the night timer is off"

reset; touch "$work/units/vekrona-update-night.timer.active"
check
night_timer_active && die "an armed night timer survived a check that found nothing"
[[ "$(field .night_armed)" == false ]] || die "night_armed is not false: $(field .)"
log "ok: a check that finds everything installed disarms a timer armed earlier"

reset; updates; date +%F >"$VEKRONA_STATE_DIR/update-skip"
check
night_timer_active && die "tonight was skipped but the timer was armed"
[[ "$(field '{pending, night_armed}')" == '{"pending":true,"night_armed":false}' ]] || die "skipped night: $(field .)"
log "ok: today's skip date keeps the night timer off while updates stay pending"

reset; updates; date -d yesterday +%F >"$VEKRONA_STATE_DIR/update-skip"
check
night_timer_active || die "yesterday's skip kept the timer off today"
log "ok: yesterday's skip date does not count"

reset; updates; check; cp "$JSON" "$work/before.json"
echo 1 >"$work/dnf.rc"
if check; then die "a failing dnf check-upgrade was accepted"; fi
grep -q "dnf5 check-upgrade failed with exit status 1" "$work/err" || die "dnf failure not reported: $(cat "$work/err")"
cmp -s "$JSON" "$work/before.json" || die "a failed check changed updates.json"
log "ok: a failed dnf query fails the check and leaves updates.json alone"

# dnf5 upgrade --assumeno, as it prints when it leaves updates out (seen 2026-10-17: RPM Fusion's NVIDIA 615.78.08 against
# the installed 615.71.09, and Fedora's qt6-qtbase-gui without its qt6-qtbase): "name arch" rows, the section, the ending.
assumeno_skipping() {
  local section="$1" ending="$2" spec
  shift 2
  {
    printf 'Updating and loading repositories:\nRepositories loaded.\nProblem 1: package qt6-qtbase-gui requires qt6-qtbase, but none of the providers can be installed\n\n'
    printf 'Package Arch Version Repository Size\n%s:\n' "$section"
    for spec in "$@"; do printf ' %s %s 1-1.fc44 updates 76.0   B\n' "${spec%.*}" "${spec##*.}"; done
    printf '\n%s\n' "$ending"
  } >"$work/assumeno.out"
}
aborted=$'Transaction Summary:\n Upgrading: 1 package\n\nOperation aborted by the user.'

reset; updates; assumeno_skipping "Skipping packages with conflicts" "$aborted" tzdata.noarch SDL3.x86_64 SDL3.i686
check
[[ "$(field '.groups[0].items | map(.name)')" == '["claude-code","kernel"]' ]] || die "skipped updates were listed: $(field .groups)"
log "ok: updates dnf5 upgrade skips for a conflict are not listed, whatever their architecture"

reset; updates; assumeno_skipping "Skipping packages with broken dependencies" "$aborted" tzdata.noarch
check
[[ "$(field '.groups[0].items | map(.name)')" == '["SDL3","claude-code","kernel"]' ]] || die "skipped updates were listed: $(field .groups)"
log "ok: updates dnf5 upgrade skips for broken dependencies are not listed"

reset
echo '{"upgrades": [{"name": "tzdata", "arch": "noarch", "evr": "1:2026b-1.fc44", "repository": "updates"}]}' >"$work/dnf.json"
assumeno_skipping "Skipping packages with broken dependencies" "Nothing to do." tzdata.noarch
echo 0 >"$work/assumeno.rc"
check
[[ "$(field '{pending, night_armed}')" == '{"pending":false,"night_armed":false}' ]] || die "an update dnf skips kept the check pending: $(field .)"
night_timer_active && die "the night timer was armed for an update dnf skips"
grep -q 'tzdata.noarch' "$work/err" || die "the skipped update must be named in the log: $(cat "$work/err")"
log "ok: when dnf skips every listed update nothing is pending, the night timer stays off and the log names what was skipped"

reset; updates; check; cp "$JSON" "$work/before.json"
echo 2 >"$work/assumeno.rc"
if check; then die "a failing dnf5 upgrade --assumeno was accepted"; fi
grep -q "dnf5 upgrade --assumeno failed with exit status 2" "$work/err" || die "dnf failure not reported: $(cat "$work/err")"
cmp -s "$JSON" "$work/before.json" || die "a failed check changed updates.json"
log "ok: a failed dnf5 upgrade --assumeno fails the check and leaves updates.json alone"

echo 1 >"$work/assumeno.rc"
printf 'Error: Failed to download metadata\n' >"$work/assumeno.out"
if check; then die "an exit status 1 that is no declined transaction was accepted"; fi
grep -q "dnf5 upgrade --assumeno failed with exit status 1: Error: Failed to download metadata" "$work/err" || die "dnf failure not reported: $(cat "$work/err")"
cmp -s "$JSON" "$work/before.json" || die "a failed check changed updates.json"
log "ok: exit status 1 without the declined-transaction line is a failure"
