#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/update-fakes.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
make_world "$work"
JSON="$VEKRONA_STATE_DIR/updates.json"

check() { run_as_root "$REPO/libexec/vekrona-update-check" 2>"$work/err"; }
reset() {
  rm -f "$JSON" "$VEKRONA_STATE_DIR/update-skip" "$work"/units/*
  echo '{"upgrades":[]}' >"$work/dnf.json"; echo 0 >"$work/dnf.rc"
  : >"$work/flatpak.tsv"; echo '{}' >"$work/mise.json"; : >"$work/installed.tsv"
  : >"$FAKE_LOG"
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
  cat >"$work/mise.json" <<'F'
{"npm:@openai/codex": {"name": "npm:@openai/codex", "current": "0.159.3", "latest": "0.162.0"},
 "npm:@earendil-works/pi-coding-agent": {"name": "npm:@earendil-works/pi-coding-agent", "current": "0.99.2", "latest": "1.1.0"},
 "aqua:anomalyco/opencode": {"name": "aqua:anomalyco/opencode", "current": "1.18.34", "latest": "1.18.35"},
 "cursor-agent": {"name": "cursor-agent", "current": "2026.1", "latest": "2026.2"}}
F
}

reset; updates
check
want='[{"name":"System packages","items":[{"name":"SDL3","from":"3.4.17-1.fc44","to":"3.4.18-1.fc44"},{"name":"kernel","from":"6.17.1-200.fc44","to":"6.17.2-200.fc44"},{"name":"tzdata","from":"1:2026a-1.fc44","to":"1:2026b-1.fc44"}]},
{"name":"Agents","items":[{"name":"claude-code","from":"2.1.0-1","to":"2.1.3-1"},{"name":"opencode","from":"1.18.34","to":"1.18.35"},{"name":"cursor-agent","from":"2026.1","to":"2026.2"},{"name":"pi","from":"0.99.2","to":"1.1.0"},{"name":"codex","from":"0.159.3","to":"0.162.0"}]},
{"name":"Flatpak","items":[{"name":"org.signal.Signal","from":"","to":"7.1"},{"name":"dev.zed.Zed","from":"","to":""}]},
{"name":"Proton","items":[{"name":"proton-mail","from":"1.14.0-1","to":"1.15.0-1"}]}]'
[[ "$(field .groups)" == "$(jq -c . <<<"$want")" ]] || die "wrong groups: $(field .groups)"
log "ok: updates.json groups dnf, agents, Flatpak and Proton updates, claude-code with the agents, newest installed version as 'from'"

[[ "$(field '{pending, night_armed}')" == '{"pending":true,"night_armed":true}' ]] || die "wrong flags: $(field .)"
[[ "$(field '.checked | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+[+-][0-9:]+$")')" == true ]] || die "checked is not an ISO timestamp: $(field .checked)"
[[ "$(stat -c %a "$JSON")" == 644 ]] || die "updates.json mode is $(stat -c %a "$JSON")"
[[ -z "$(ls -A "$VEKRONA_STATE_DIR" | grep -v '^updates.json$')" ]] || die "left files behind: $(ls -A "$VEKRONA_STATE_DIR")"
night_timer_active || die "pending updates did not arm the night timer"
[[ "$(sed -n 1p "$FAKE_LOG")" == "vekrona-proton stage" ]] || die "the Proton repo was not staged first: $(cat "$FAKE_LOG")"
log "ok: pending is true, the night timer is armed, the file is world-readable, whole, and Proton was staged first"

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

reset; updates; echo 'not json' >"$work/mise.json"
if check; then die "unreadable mise output was accepted"; fi
[[ ! -e "$JSON" ]] || die "a failed check wrote updates.json"
log "ok: unreadable mise output fails the check"
