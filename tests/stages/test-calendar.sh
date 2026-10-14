#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" XDG_CONFIG_HOME="$scratch/home/.config" XDG_STATE_HOME="$scratch/state"
mkdir -p "$XDG_CONFIG_HOME/khal"
cp "$ROOT/config/khal/config" "$XDG_CONFIG_HOME/khal/config"
calendars="$HOME/.local/share/vekrona-calendars"
output="$XDG_STATE_HOME/vekrona/calendar.json"
today="$(date +%Y-%m-%d)"
tomorrow="$(date -d tomorrow +%Y-%m-%d)"

render() { "$ROOT/bin/vekrona-calendar" render; }
# jq -e fails the test on false or null.
assert_json() { jq -e "$1" "$output" >/dev/null || die "$2: $(cat "$output")"; }
write_event() {
  local dir="$1" uid="$2" title="$3"
  shift 3
  mkdir -p "$dir"
  { printf 'BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//vekrona//test//EN\nBEGIN:VEVENT\nUID:%s@vekrona\nDTSTAMP:20200101T000000Z\nSUMMARY:%s\n' "$uid" "$title"
    printf '%s\n' "$@"
    printf 'END:VEVENT\nEND:VCALENDAR\n'; } >"$dir/$uid.ics"
}
compact() { date -d "$1" +%Y%m%d; }

render
assert_json '.events == [] and .configured == false' "a missing calendar root must give an empty, unconfigured calendar"
[[ -d "$calendars" ]] || die "render must create the calendar root"
rmdir "$calendars"
mkdir -p "$calendars"
render
assert_json '.events == []' "an empty calendar root must give no events"
log "ok: an empty or missing calendar root gives no events"

write_event "$calendars/fixture" weekly "Weekly sync" \
  "DTSTART:$(compact "$today - 7 days")T100000" "DTEND:$(compact "$today - 7 days")T110000" "RRULE:FREQ=WEEKLY"
render
assert_json "[.events[] | select(.title == \"Weekly sync\")] | map(.start) | .[0] == \"$today 10:00\"" "the weekly event's occurrence today must be expanded from the recurrence"
assert_json '[.events[] | select(.title == "Weekly sync")] | length >= 4' "a weekly event must recur across the 31-day horizon"
assert_json '.configured == false' "without a vdirsyncer config the calendar is not configured"
log "ok: a recurring event is expanded into its occurrences"

write_event "$calendars/fixture" allday "Holiday" \
  "DTSTART;VALUE=DATE:$(compact "$today")" "DTEND;VALUE=DATE:$(compact "$tomorrow")"
write_event "$calendars/fixture" midnight "Night shift" \
  "DTSTART:$(compact "$today")T230000" "DTEND:$(compact "$tomorrow")T010000"
write_event "$calendars/fixture" unicode 'Quote "q" \\ café 東京' \
  "DTSTART:$(compact "$today")T120000" "DTEND:$(compact "$today")T130000"
render
assert_json '[.events[] | select(.title == "Holiday")] | map(.allDay) == [true]' "an all-day event must be flagged allDay"
assert_json '[.events[] | select(.title == "Weekly sync")][0].allDay == false' "a timed event must not be flagged allDay"
assert_json "[.events[] | select(.title == \"Night shift\")] | map([.start, .end]) == [[\"$today 23:00\", \"$tomorrow 01:00\"]]" "an event spanning midnight must be listed once with its real start and end"
assert_json '[.events[] | select(.title | startswith("Quote"))] | map(.title) == ["Quote \"q\" \\ café 東京"]' "quotes, backslashes and unicode must survive"
assert_json '[.events[].start] == ([.events[].start] | sort)' "events must be sorted by start"
log "ok: all-day, midnight-spanning and unicode events render correctly"

mkdir -p "$XDG_CONFIG_HOME/vdirsyncer"
vdirsyncer_config="$XDG_CONFIG_HOME/vdirsyncer/config"
# One pair of a vdirsyncer config: the remote storage holds $2 as its url.
pair_config() {
  printf '[pair %s]\na = "%s_remote"\nb = "%s_local"\n\n[storage %s_remote]\ntype = "http"\nurl = "%s"\n\n[storage %s_local]\ntype = "filesystem"\n\n' \
    "$1" "$1" "$1" "$1" "$2" "$1"
}
: >"$vdirsyncer_config"
render
assert_json '.configured == false' "a vdirsyncer config without a pair is not configured"
pair_config proton https://example.com/ical >"$vdirsyncer_config"
render
assert_json '.configured == true' "a vdirsyncer config with a filled-in pair makes the calendar configured"
log "ok: a filled-in pair marks the calendar configured"

fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
printf '#!/usr/bin/env bash\necho "Error: pair x: need to run vdirsyncer discover" >&2\nexit 1\n' >"$fake_bin/vdirsyncer"
chmod +x "$fake_bin/vdirsyncer"
rm "$output"
if PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err"; then
  die "a failing vdirsyncer must fail the sync"
fi
# shellcheck disable=SC2016 # the backticks are literal text of the message
grep -q 'run `vdirsyncer discover` once by hand' "$scratch/sync.err" || die "a pair that needs discovery must tell the user to run vdirsyncer discover"
[[ -f "$output" ]] || die "a failing sync must still render the calendar"
log "ok: a failing sync still renders and fails the unit"

secret_url='https://calendar.example.com/ical/user%40example.com/private-s3cr3t/basic.ics?token=s3cr3t'
printf '#!/usr/bin/env bash\necho "Error: pair x: storage y: %s: 500 Server Error" >&2\nexit 1\n' "$secret_url" >"$fake_bin/vdirsyncer"
PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err" || true
grep -q 's3cr3t' "$scratch/sync.err" && die "a vdirsyncer error must not print a private calendar URL: $(cat "$scratch/sync.err")"
grep -q 'https://calendar.example.com' "$scratch/sync.err" || die "the redacted URL must keep its host: $(cat "$scratch/sync.err")"
grep -q '500 Server Error' "$scratch/sync.err" || die "redacting a URL must keep the rest of the error: $(cat "$scratch/sync.err")"
log "ok: a URL in a sync error is cut to its host"

# The shipped template holds one pair per provider. Filling in one provider must be enough: the sync runs for that
# pair alone and the placeholder pairs are skipped without a word.
cp "$ROOT/config/vdirsyncer/config.example" "$vdirsyncer_config"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$scratch/vdirsyncer.calls" >"$fake_bin/vdirsyncer"
rm -f "$output" "$scratch/vdirsyncer.calls"
if PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err"; then
  die "a config whose pairs are all placeholders must fail a sync run by hand"
fi
grep -q 'no pair' "$scratch/sync.err" || die "the error must say that no pair is filled in: $(cat "$scratch/sync.err")"
[[ ! -e "$scratch/vdirsyncer.calls" ]] || die "vdirsyncer must not run while every pair is a placeholder"
assert_json '.configured == false' "a config of placeholder pairs must render as not configured"
log "ok: a sync by hand with only placeholder pairs fails before vdirsyncer runs"

sed -i 's#/url/PLACEHOLDER/calendar.ics?CacheKey=PLACEHOLDER&PassphraseKey=PLACEHOLDER#/url/id/calendar.ics?CacheKey=k\&PassphraseKey=p#' "$vdirsyncer_config"
rm -f "$output"
PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err" || die "a filled-in pair must sync: $(cat "$scratch/sync.err")"
[[ "$(cat "$scratch/vdirsyncer.calls")" == $'metasync proton\nsync proton' ]] \
  || die "only the filled-in pair may be synced: $(cat "$scratch/vdirsyncer.calls")"
assert_json '.configured == true' "one filled-in pair among placeholder pairs must render as configured"
log "ok: with one provider filled in, only its pair is synced and the placeholder pairs are skipped"

# A commented-out line does not count: not a PLACEHOLDER in a comment, and not a storage definition either.
sed -i 's/^url = "https:\/\/calendar.google.com.*/url = "https:\/\/google.example.com\/ical"\n# url = "PLACEHOLDER"/' "$vdirsyncer_config"
rm -f "$scratch/vdirsyncer.calls"
PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err" || die "a commented-out PLACEHOLDER must not block a pair: $(cat "$scratch/sync.err")"
[[ "$(cat "$scratch/vdirsyncer.calls")" == $'metasync proton google\nsync proton google' ]] \
  || die "a pair with a commented-out PLACEHOLDER must be synced: $(cat "$scratch/vdirsyncer.calls")"
sed -i 's/^\[storage proton_local\]/# [storage proton_local]/' "$vdirsyncer_config"
rm -f "$output"
if PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err"; then
  die "a pair that uses a storage the config does not define must fail the sync"
fi
grep -q 'proton_local' "$scratch/sync.err" || die "the error must name the missing storage: $(cat "$scratch/sync.err")"
log "ok: a pair that uses an undefined storage fails the sync"

# systemd's ExecCondition: 0 runs the sync, 1-254 skip the unit without failing it, 255 fails it.
status_of() { local status=0; "$@" 2>/dev/null || status=$?; echo "$status"; }
cp "$ROOT/config/vdirsyncer/config.example" "$vdirsyncer_config"
rm -f "$output"
[[ "$(status_of "$ROOT/bin/vekrona-calendar" configured)" == 1 ]] || die "a config of placeholder pairs must skip the unit (exit 1)"
assert_json '.configured == false' "skipping the unit must still render the not-configured calendar"
rm "$vdirsyncer_config"
rm -f "$output"
[[ "$(status_of "$ROOT/bin/vekrona-calendar" configured)" == 1 ]] || die "a missing config must skip the unit (exit 1)"
assert_json '.configured == false' "a missing config must render as not configured"
pair_config proton https://example.com/ical >"$vdirsyncer_config"
pair_config google https://PLACEHOLDER.example.com/ >>"$vdirsyncer_config"
[[ "$(status_of "$ROOT/bin/vekrona-calendar" configured)" == 0 ]] || die "a config with a filled-in pair must run the unit (exit 0)"
sed -i 's/^b = "google_local"/b = "nowhere"/' "$vdirsyncer_config"
[[ "$(status_of "$ROOT/bin/vekrona-calendar" configured)" == 255 ]] || die "a pair that uses an undefined storage must fail the unit (exit 255), not skip it"
rm "$vdirsyncer_config"
mkdir -p "$scratch/readonly"
chmod 500 "$scratch/readonly"
[[ "$(status_of env XDG_STATE_HOME="$scratch/readonly/state" "$ROOT/bin/vekrona-calendar" configured)" == 255 ]] \
  || die "a render that breaks must fail the unit (exit 255), not skip it"
chmod 700 "$scratch/readonly"
log "ok: an unconfigured calendar skips the unit, a broken config or render fails it"
