#!/usr/bin/env bash
set -euo pipefail

fail() { echo "errors-check FAILED: $*" >&2; exit 1; }

command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"
command -v jq >/dev/null 2>&1 || fail "jq not installed"
command -v vekrona-error >/dev/null 2>&1 || fail "vekrona-error not on PATH"
command -v coredumpctl >/dev/null 2>&1 || fail "coredumpctl not installed"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

STORE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vekrona/errors"
MUTE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/vekrona/errors-mute"
mkdir -p "$STORE_DIR"

CREATED_IDS=()
MUTE_PATTERN=""

cleanup() {
  for id in "${CREATED_IDS[@]:-}"; do
    [[ -n "$id" ]] && vekrona-error rm "$id" >/dev/null 2>&1 || true
  done
  if [[ -n "$MUTE_PATTERN" && -f "$MUTE_FILE" ]]; then
    grep -vxF "$MUTE_PATTERN" "$MUTE_FILE" > "$MUTE_FILE.tmp" 2>/dev/null || true
    mv "$MUTE_FILE.tmp" "$MUTE_FILE" 2>/dev/null || true
  fi
  systemctl --user stop vekrona-errors-check-fail.service >/dev/null 2>&1 || true
  systemctl --user stop sway-session.target >/dev/null 2>&1 || true
  if [[ -n "${SWAY_WATCH_PID:-}" ]]; then
    kill "$SWAY_WATCH_PID" >/dev/null 2>&1 || true
  fi
  systemctl --user stop vekrona-sway-errors-check.service >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_until() {
  local timeout="$1" deadline; shift
  deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    inotifywait -qq -t 1 -e create,modify,moved_to,close_write "$STORE_DIR" >/dev/null 2>&1 || true
  done
}

store_ids() { ls "$STORE_DIR" 2>/dev/null | sort; }

store_count_gt() { [[ "$(ls "$STORE_DIR" 2>/dev/null | wc -l)" -gt "$1" ]]; }

wait_for_new_id() {
  local before="$1" timeout="${2:-30}" before_count new_id
  before_count="$(grep -c . <<<"$before" || true)"
  wait_until "$timeout" store_count_gt "$before_count" || return 1
  new_id="$(comm -13 <(printf '%s\n' "$before") <(store_ids) | tail -1)"
  [[ -n "$new_id" ]] || return 1
  printf '%s' "$new_id"
}

record_field() { jq -r --arg k "$2" '.[$k]' "$STORE_DIR/$1/record.json"; }

# --- bring up a headless sway session: this starts dms.service and
#     vekrona-errors.service as Wants of sway-session.target, the same way
#     a real login does ---

systemctl --user reset-failed vekrona-sway-errors-check.service >/dev/null 2>&1 || true
pgrep -x sway >/dev/null && fail "a sway process is already running"
find "$XDG_RUNTIME_DIR" -maxdepth 1 -regextype posix-extended \
  -regex '.*/sway-ipc\.[0-9]+\.[0-9]+\.sock' -delete

coproc SWAY_WATCH {
  inotifywait -e create --include 'sway-ipc\.[0-9]+\.[0-9]+\.sock$' \
    --format '%f' -t 60 "$XDG_RUNTIME_DIR" 2>&1
}
IFS= read -r -u "${SWAY_WATCH[0]}" watch_line
[[ "$watch_line" == "Watches established." ]] || fail "could not set up the sway ipc socket watch"

systemd-run --user --unit vekrona-sway-errors-check \
  --setenv=WLR_BACKENDS=headless --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
  -- sway -c "$HOME/.config/sway/config" --unsupported-gpu \
  || fail "could not start sway via systemd-run"

IFS= read -r -u "${SWAY_WATCH[0]}" sockname || fail "sway ipc socket never appeared"
export SWAYSOCK="$XDG_RUNTIME_DIR/$sockname"
[[ -S "$SWAYSOCK" ]] || fail "sway ipc socket not found: $SWAYSOCK"

systemctl --user start sway-session.target || fail "sway-session.target did not become active"

wait_until 30 systemctl --user is-active vekrona-errors \
  || fail "vekrona-errors.service did not become active"
echo "ok: vekrona-errors.service active"

# --- source: manual report ---

before="$(store_ids)"
vekrona-error report --title "errors-check manual report" --summary "manual source" --source manual
manual_id="$(wait_for_new_id "$before" 30)" || fail "manual report did not produce a record"
CREATED_IDS+=("$manual_id")
[[ "$(record_field "$manual_id" source)" == manual ]] || fail "manual report recorded with wrong source"
echo "ok: manual report -> $manual_id"

# --- source: root report lands in this user's store ---

before="$(store_ids)"
sudo vekrona-error report --title "errors-check root report" --summary "from root" --source manual
root_id="$(wait_for_new_id "$before" 30)" || fail "root report did not produce a record"
CREATED_IDS+=("$root_id")
echo "ok: root report -> $root_id"

# --- source: failing user unit ---

before="$(store_ids)"
systemctl --user reset-failed vekrona-errors-check-fail.service >/dev/null 2>&1 || true
systemd-run --user --unit=vekrona-errors-check-fail false || true
unit_id="$(wait_for_new_id "$before" 30)" || fail "a failing user unit did not produce a record"
CREATED_IDS+=("$unit_id")
[[ "$(record_field "$unit_id" source)" == unit ]] || fail "failing unit recorded with wrong source"
echo "ok: failing user unit -> $unit_id"

# --- source: coredump ---

before="$(store_ids)"
bash -c 'kill -SEGV $$' || true
coredump_id="$(wait_for_new_id "$before" 60)" || fail "a coredump did not produce a record"
CREATED_IDS+=("$coredump_id")
[[ "$(record_field "$coredump_id" source)" == coredump ]] || fail "coredump recorded with wrong source"
echo "ok: coredump -> $coredump_id"

# --- source: journal (generic high-priority log line) ---

marker1="vekrona-errors-check-$RANDOM$RANDOM"
before="$(store_ids)"
logger -p user.err "$marker1"
journal_id="$(wait_for_new_id "$before" 30)" || fail "a logger journal entry did not produce a record"
CREATED_IDS+=("$journal_id")
[[ "$(record_field "$journal_id" source)" == journal ]] || fail "journal entry recorded with wrong source"
echo "ok: generic journal entry -> $journal_id"

# --- repeat bumps count ---

count_before="$(record_field "$journal_id" count)"
logger -p user.err "$marker1"
wait_until 30 bash -c "[[ \"\$(jq -r .count '$STORE_DIR/$journal_id/record.json')\" -gt $count_before ]]" \
  || fail "repeating the same error did not bump its count"
echo "ok: repeat bumps count ($count_before -> $(record_field "$journal_id" count))"

# --- mute suppresses further updates ---

MUTE_PATTERN="^$(record_field "$journal_id" fingerprint)\$"
vekrona-error mute "$journal_id"
[[ "$(record_field "$journal_id" status)" == muted ]] || fail "mute did not set status=muted"

muted_count="$(record_field "$journal_id" count)"
logger -p user.err "$marker1"
marker2="vekrona-errors-check-sentinel-$RANDOM$RANDOM"
before="$(store_ids)"
logger -p user.err "$marker2"
sentinel_id="$(wait_for_new_id "$before" 30)" || fail "a sentinel entry after muting did not produce a record"
CREATED_IDS+=("$sentinel_id")
[[ "$(record_field "$journal_id" count)" == "$muted_count" ]] \
  || fail "a muted error's count changed after being re-triggered"
echo "ok: mute suppresses further updates to $journal_id"

# --- unread updates ---

unread_before="$(cat "$STORE_DIR/unread")"
marker3="vekrona-errors-check-unread-$RANDOM$RANDOM"
before="$(store_ids)"
logger -p user.err "$marker3"
unread_id="$(wait_for_new_id "$before" 30)" || fail "an unread-test entry did not produce a record"
CREATED_IDS+=("$unread_id")
wait_until 10 bash -c "[[ \"\$(cat '$STORE_DIR/unread')\" -gt $unread_before ]]" \
  || fail "the unread count did not increase for a new error"
unread_after_new="$(cat "$STORE_DIR/unread")"
vekrona-error ack "$unread_id"
wait_until 10 bash -c "[[ \"\$(cat '$STORE_DIR/unread')\" -lt $unread_after_new ]]" \
  || fail "the unread count did not decrease after ack"
echo "ok: unread file tracks new/ack transitions"

# --- cursor resume across a watcher restart ---

systemctl --user stop vekrona-errors
marker4="vekrona-errors-check-resume-$RANDOM$RANDOM"
logger -p user.err "$marker4"
before="$(store_ids)"
systemctl --user start vekrona-errors
wait_until 30 systemctl --user is-active vekrona-errors \
  || fail "vekrona-errors.service did not come back up after being restarted"
resume_id="$(wait_for_new_id "$before" 30)" \
  || fail "an error logged while the watcher was stopped was not picked up on resume"
CREATED_IDS+=("$resume_id")
echo "ok: cursor resume picked up $resume_id logged while the watcher was stopped"

# --- desktop notification carries the fix action ---

notify_log="$(mktemp)"
timeout 20 dbus-monitor --session "interface='org.freedesktop.Notifications',member='Notify'" \
  >"$notify_log" 2>&1 &
monitor_pid=$!
marker5="vekrona-errors-check-notify-$RANDOM$RANDOM"
before="$(store_ids)"
logger -p user.err "$marker5"
notify_id="$(wait_for_new_id "$before" 30)" || fail "a notify-test entry did not produce a record"
CREATED_IDS+=("$notify_id")
wait "$monitor_pid" || true
grep -q 'member=Notify' "$notify_log" || fail "dbus-monitor did not observe a Notify call"
grep -q '"fix"' "$notify_log" || fail "the Notify call did not carry a 'fix' action"
rm -f "$notify_log"
echo "ok: a Notify call with the fix action was observed on the session bus"

echo "errors-check OK"
