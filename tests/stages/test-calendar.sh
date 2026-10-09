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
: >"$XDG_CONFIG_HOME/vdirsyncer/config"
render
assert_json '.configured == true' "a vdirsyncer config makes the calendar configured"
log "ok: a vdirsyncer config marks the calendar configured"

fake_bin="$scratch/bin"
mkdir -p "$fake_bin"
printf '#!/usr/bin/env bash\necho "Error: pair x: need to run vdirsyncer discover" >&2\nexit 1\n' >"$fake_bin/vdirsyncer"
chmod +x "$fake_bin/vdirsyncer"
rm "$output"
if PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err"; then
  die "a failing vdirsyncer must fail the sync"
fi
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

cp "$ROOT/config/vdirsyncer/config.example" "$XDG_CONFIG_HOME/vdirsyncer/config"
printf '#!/usr/bin/env bash\necho called >"%s"\necho "fake vdirsyncer must not run" >&2\nexit 1\n' "$scratch/vdirsyncer.called" >"$fake_bin/vdirsyncer"
rm -f "$output"
if PATH="$fake_bin:$PATH" "$ROOT/bin/vekrona-calendar" sync 2>"$scratch/sync.err"; then
  die "a config that still has placeholder storages must fail the sync"
fi
for storage in proton_remote google_remote microsoft_remote; do
  grep -q "$storage" "$scratch/sync.err" || die "the error must name the placeholder storage $storage: $(cat "$scratch/sync.err")"
done
[[ ! -e "$scratch/vdirsyncer.called" ]] || die "vdirsyncer must not run while placeholder storages remain"
assert_json '.configured == true' "a placeholder config must still render the calendar"
log "ok: a config with placeholder storages fails before vdirsyncer runs and names them"
