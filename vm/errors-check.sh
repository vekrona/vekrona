#!/usr/bin/env bash
set -euo pipefail

fail() { echo "errors-check FAILED: $*" >&2; exit 1; }

# shellcheck source=vm/session-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

require_cmds() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || fail "$c not installed"; done
}

setup_env() {
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  STORE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vekrona/errors"
  MUTE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/vekrona/errors-mute"
  mkdir -p "$STORE_DIR"
}

CREATED_IDS=()
MUTE_PATTERN=""

cleanup() {
  local id
  for id in "${CREATED_IDS[@]:-}"; do
    [[ -n "$id" ]] && vekrona-error rm "$id" >/dev/null 2>&1 || true
  done
  if [[ -n "$MUTE_PATTERN" && -f "$MUTE_FILE" ]]; then
    grep -vxF "$MUTE_PATTERN" "$MUTE_FILE" > "$MUTE_FILE.tmp" 2>/dev/null || true
    mv "$MUTE_FILE.tmp" "$MUTE_FILE" 2>/dev/null || true
  fi
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

marker_matches() { grep -rl -F -- "$1" "$STORE_DIR"/*/record.json >/dev/null 2>&1; }

find_record_by_marker() {
  local marker="$1" timeout="${2:-30}"
  wait_until "$timeout" marker_matches "$marker" || return 1
  grep -rl -F -- "$marker" "$STORE_DIR"/*/record.json 2>/dev/null | head -1 | xargs dirname | xargs basename
}

record_field() { jq -r --arg k "$2" '.[$k]' "$STORE_DIR/$1/record.json"; }

wait_for_watcher_active() {
  wait_until 30 systemctl --user is-active vekrona-errors \
    || fail "vekrona-errors.service did not become active"
  echo "ok: vekrona-errors.service active"
}

check_manual_report() {
  local marker="vekrona-errors-check-manual-$RANDOM$RANDOM" id
  vekrona-error report --title "$marker" --summary "manual source" --source manual
  id="$(find_record_by_marker "$marker" 30)" || fail "a manual report did not produce a record"
  CREATED_IDS+=("$id")
  [[ "$(record_field "$id" source)" == manual ]] || fail "manual report recorded with the wrong source"
  echo "ok: manual report -> $id"
}

check_root_report() {
  local marker="vekrona-errors-check-root-$RANDOM$RANDOM" id
  sudo "$(command -v vekrona-error)" report --title "$marker" --summary "from root" --source manual
  id="$(find_record_by_marker "$marker" 30)" || fail "a root report did not produce a record"
  CREATED_IDS+=("$id")
  echo "ok: root report -> $id"
}

check_failing_unit() {
  local id unit_name="vekrona-errors-check-fail-$RANDOM$RANDOM"
  systemd-run --user --collect --unit="$unit_name" false || true
  id="$(find_record_by_marker "$unit_name.service" 30)" \
    || fail "a failing user unit did not produce a record"
  CREATED_IDS+=("$id")
  [[ "$(record_field "$id" source)" == unit ]] || fail "failing unit recorded with the wrong source"
  echo "ok: failing user unit -> $id"
}

check_coredump() {
  local id crash_pid
  ( kill -SEGV "$BASHPID" ) &
  crash_pid=$!
  wait "$crash_pid" 2>/dev/null || true
  id="$(find_record_by_marker "$crash_pid" 60)" || fail "a coredump did not produce a record"
  CREATED_IDS+=("$id")
  [[ "$(record_field "$id" source)" == coredump ]] || fail "coredump recorded with the wrong source"
  echo "ok: coredump -> $id"
}

check_generic_journal() {
  JOURNAL_MARKER="vekrona-errors-check-journal-$RANDOM$RANDOM"
  logger -p user.err "$JOURNAL_MARKER"
  JOURNAL_ID="$(find_record_by_marker "$JOURNAL_MARKER" 30)" \
    || fail "a plain journal entry did not produce a record"
  CREATED_IDS+=("$JOURNAL_ID")
  [[ "$(record_field "$JOURNAL_ID" source)" == journal ]] || fail "journal entry recorded with the wrong source"
  echo "ok: generic journal entry -> $JOURNAL_ID"
}

check_repeat_bumps_count() {
  local count_before
  count_before="$(record_field "$JOURNAL_ID" count)"
  logger -p user.err "$JOURNAL_MARKER"
  wait_until 30 bash -c "[[ \"\$(jq -r .count '$STORE_DIR/$JOURNAL_ID/record.json')\" -gt $count_before ]]" \
    || fail "repeating the same error did not bump its count"
  echo "ok: repeat bumps count ($count_before -> $(record_field "$JOURNAL_ID" count))"
}

check_mute_suppresses() {
  MUTE_PATTERN="^$(record_field "$JOURNAL_ID" fingerprint)\$"
  vekrona-error mute "$JOURNAL_ID"
  [[ "$(record_field "$JOURNAL_ID" status)" == muted ]] || fail "mute did not set status=muted"

  local muted_count marker2 sentinel_id
  muted_count="$(record_field "$JOURNAL_ID" count)"
  logger -p user.err "$JOURNAL_MARKER"
  marker2="vekrona-errors-check-sentinel-$RANDOM$RANDOM"
  logger -p user.err "$marker2"
  sentinel_id="$(find_record_by_marker "$marker2" 30)" \
    || fail "a sentinel entry after muting did not produce a record"
  CREATED_IDS+=("$sentinel_id")
  [[ "$(record_field "$JOURNAL_ID" count)" == "$muted_count" ]] \
    || fail "a muted error's count changed after being re-triggered"
  echo "ok: mute suppresses further updates to $JOURNAL_ID"
}

check_unread_tracks() {
  local unread_before marker id unread_after_new
  unread_before="$(cat "$STORE_DIR/unread")"
  marker="vekrona-errors-check-unread-$RANDOM$RANDOM"
  logger -p user.err "$marker"
  id="$(find_record_by_marker "$marker" 30)" || fail "an unread-test entry did not produce a record"
  CREATED_IDS+=("$id")
  wait_until 10 bash -c "[[ \"\$(cat '$STORE_DIR/unread')\" -gt $unread_before ]]" \
    || fail "the unread count did not increase for a new error"
  unread_after_new="$(cat "$STORE_DIR/unread")"
  vekrona-error ack "$id"
  wait_until 10 bash -c "[[ \"\$(cat '$STORE_DIR/unread')\" -lt $unread_after_new ]]" \
    || fail "the unread count did not decrease after ack"
  echo "ok: unread file tracks new/ack transitions"
}

check_ack_all_clears_unread() {
  local marker id
  marker="vekrona-errors-check-ack-all-$RANDOM$RANDOM"
  logger -p user.err "$marker"
  id="$(find_record_by_marker "$marker" 30)" || fail "an ack-all entry did not produce a record"
  CREATED_IDS+=("$id")
  wait_until 10 bash -c "[[ \"\$(cat '$STORE_DIR/unread')\" -gt 0 ]]" \
    || fail "the unread count did not rise above 0 for a new error"
  vekrona-error ack --all
  [[ "$(cat "$STORE_DIR/unread")" == 0 ]] || fail "unread is not 0 after ack --all"
  [[ "$(record_field "$id" status)" == seen ]] || fail "ack --all did not set status=seen"
  echo "ok: ack --all marks every new error seen and resets unread to 0"
}

check_cursor_resume() {
  local marker id
  systemctl --user stop vekrona-errors
  marker="vekrona-errors-check-resume-$RANDOM$RANDOM"
  logger -p user.err "$marker"
  systemctl --user start vekrona-errors
  wait_until 30 systemctl --user is-active vekrona-errors \
    || fail "vekrona-errors.service did not come back up after being restarted"
  id="$(find_record_by_marker "$marker" 30)" \
    || fail "an error logged while the watcher was stopped was not picked up on resume"
  CREATED_IDS+=("$id")
  echo "ok: cursor resume picked up $id logged while the watcher was stopped"
}

wait_for_dbus_monitor_ready() {
  local fd="$1" timeout="$2" deadline line
  deadline=$((SECONDS + timeout))
  while IFS= read -r -t 5 -u "$fd" line; do
    [[ "$line" == *NameLost* ]] && return 0
    (( SECONDS < deadline )) || return 1
  done
  return 1
}

read_notify_with_fix() {
  local fd="$1" timeout="$2" deadline line saw_notify=0 saw_fix=0
  deadline=$((SECONDS + timeout))
  while IFS= read -r -t 5 -u "$fd" line; do
    [[ "$line" == *"member=Notify"* ]] && saw_notify=1
    [[ "$line" == *'"fix"'* ]] && saw_fix=1
    (( saw_notify && saw_fix )) && return 0
    (( SECONDS < deadline )) || return 1
  done
  (( saw_notify && saw_fix ))
}

check_notify_fix_action() {
  local marker="vekrona-errors-check-notify-$RANDOM$RANDOM" id mon_pid

  coproc DBUS_MON { dbus-monitor --session; }
  mon_pid=$DBUS_MON_PID

  wait_for_dbus_monitor_ready "${DBUS_MON[0]}" 10 \
    || { kill "$mon_pid" 2>/dev/null; fail "dbus-monitor did not become ready to monitor"; }

  logger -p user.err "$marker"

  read_notify_with_fix "${DBUS_MON[0]}" 20 \
    || { kill "$mon_pid" 2>/dev/null; fail "dbus-monitor did not observe a Notify call carrying a 'fix' action"; }
  kill "$mon_pid" 2>/dev/null
  wait "$mon_pid" 2>/dev/null || true

  id="$(find_record_by_marker "$marker" 30)" || fail "a notify-test entry did not produce a record"
  CREATED_IDS+=("$id")
  echo "ok: a Notify call with the fix action was observed on the session bus"
}

check_no_notify_failures_logged() {
  journalctl --user -u vekrona-errors --since "$TEST_START" --no-pager 2>/dev/null \
    | grep -q "failed to send a desktop notification" \
    && fail "the watcher logged a failed Notify call during this test run"
  echo "ok: no failed Notify calls logged during this test run"
}

main() {
  require_cmds inotifywait jq vekrona-error coredumpctl dbus-monitor logger
  setup_env
  TEST_START="$(date -Iseconds)"
  session_attach_existing \
    || fail "no live sway session found (expected session-check.sh to have brought one up already)"
  wait_for_watcher_active
  check_manual_report
  check_root_report
  check_failing_unit
  check_coredump
  check_generic_journal
  check_repeat_bumps_count
  check_mute_suppresses
  check_unread_tracks
  check_ack_all_clears_unread
  check_cursor_resume
  check_notify_fix_action
  check_no_notify_failures_logged
  echo "errors-check OK"
}

main "$@"
