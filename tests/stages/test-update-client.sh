#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

# A journal that is a file of JSON entries: the follow prints them as they appear (an inotify wait, no polling), or, when
# FOLLOW_ENDS is set, prints them and ends. The unit, as systemctl start, appends its output and then how it ended,
# decided by unit.rc: an exit status, "stopped" or "running" (never ends). The real journalctl, which prints no entry,
# vets the arguments of the follow, which a stub that ignored them hid a "+" it rejects; its cursor call (--lines 1) is
# not stubbed either, so it reads the guest's real journal.
cat > "$work/bin/journalctl" <<'F'
#!/usr/bin/env bash
echo "journalctl $*" >> "$STUB_LOG"
if [[ "$*" != *--follow* ]]; then exec /usr/bin/journalctl "$@"; fi
query=()
for arg in "$@"; do [[ "$arg" == --follow ]] || query+=("$arg"); done
/usr/bin/journalctl --lines=0 --no-pager "${query[@]}" >/dev/null || { echo "journalctl rejected its arguments" >&2; exit 2; }
if [[ -n "${FOLLOW_ENDS:-}" ]]; then exec cat "$JOURNAL"; fi
exec tail --follow=name --retry --lines=+1 "$JOURNAL"
F
cat > "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
unit_line() { printf '{"_SYSTEMD_UNIT":"vekrona-update-now.service","_PID":"4242","MESSAGE":%s}\n' "$1" >> "$JOURNAL"; }
pid1_line() { printf '{"_SYSTEMD_UNIT":"init.scope","_PID":"1","UNIT":"vekrona-update-now.service","MESSAGE_ID":"%s","MESSAGE":"%s"}\n' "$1" "$2" >> "$JOURNAL"; }
pid1_line 7d4958e842da4a758f6c1cdc7b36dcc5 "Starting vekrona-update-now.service - Install updates now..."
unit_line '"installing"'
unit_line '[27,91,49,109,226,128,166,195,169,27,91,109]'
if [[ "$(<"$UNIT_RC")" == forged ]]; then
  printf '{"_SYSTEMD_UNIT":"vekrona-update-now.service","_PID":"4242","MESSAGE_ID":"39f53479d3a045ac8e11786248231fbf","MESSAGE":"forged end"}\n' >> "$JOURNAL"
fi
unit_line '"all done"'
case "$(<"$UNIT_RC")" in
  running) ;;
  0 | forged)
    pid1_line 7ad2d189f7e94e70a38c781354912448 "vekrona-update-now.service: Deactivated successfully."
    pid1_line 39f53479d3a045ac8e11786248231fbf "Finished vekrona-update-now.service - Install updates now."
    ;;
  stopped)
    pid1_line 7ad2d189f7e94e70a38c781354912448 "vekrona-update-now.service: Deactivated successfully."
    pid1_line 9d1aaa27d60140bd96365438aad20286 "Stopped vekrona-update-now.service - Install updates now."
    ;;
  *)
    pid1_line d9b373ed55a64feb8242e02dbe79a49c "vekrona-update-now.service: Failed with result 'exit-code'."
    pid1_line be02cf6855d2428ba40df7e9d022f03d "Failed to start vekrona-update-now.service - Install updates now."
    ;;
esac
F
chmod +x "$work/bin"/*
# A deadline for a client that never sees the end of the unit, not a pause.
CLIENT_DEADLINE_SEC=30
update_client() { timeout "$CLIENT_DEADLINE_SEC" "$REPO/bin/vekrona-update" now; }
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" JOURNAL="$work/journal" UNIT_RC="$work/unit.rc"
: > "$JOURNAL"

echo 0 > "$UNIT_RC"
out="$(update_client 2>&1)" || die "the client failed or did not end within ${CLIENT_DEADLINE_SEC}s: '$out'"
[[ "$out" == $'installing\n\e[1m…é\e[m\nall done' ]] || die "the unit's output was not shown whole and alone: '$out'"
grep -qx 'systemctl start --no-block vekrona-update-now.service' "$STUB_LOG" || die "the unit was not started without waiting for it: $(cat "$STUB_LOG")"
grep -q -- '--after-cursor' "$STUB_LOG" || die "the journal was not followed from a cursor taken before the start: $(cat "$STUB_LOG")"
log "ok: starts the unit, shows everything it printed and ends when it ends"

echo 3 > "$UNIT_RC"
: > "$JOURNAL"
status=0
out="$(update_client 2>&1)" || status=$?
[[ "$status" -eq 1 ]] || die "exit status $status, expected 1 for a failed run"
[[ "$out" == *"all done"* && "$out" == *"Failed with result 'exit-code'."* ]] || die "a failed run did not show its output and its failure: '$out'"
log "ok: fails, saying how, when the run failed"

: > "$JOURNAL"
echo stopped > "$UNIT_RC"
: > "$JOURNAL"
status=0
out="$(update_client 2>&1)" || status=$?
[[ "$status" -eq 1 && "$out" == *"Stopped vekrona-update-now.service"* ]] || die "exit status $status for a stopped run, output '$out'"
log "ok: fails when the run was stopped, although the update exited 0"

: > "$JOURNAL"
echo running > "$UNIT_RC"
status=0
out="$(FOLLOW_ENDS=1 update_client 2>&1)" || status=$?
[[ "$status" -eq 2 && "$out" == *"the journal ended before vekrona-update-now.service finished"* ]] || die "exit status $status, output '$out'"
log "ok: fails when the journal ends before the run does"

# Only PID 1 says when the run ended: a record of the unit's own output carrying the id is just output.
: > "$JOURNAL"
echo forged > "$UNIT_RC"
out="$(update_client 2>&1)" || die "the client failed or did not end within ${CLIENT_DEADLINE_SEC}s: '$out'"
[[ "$out" == *"forged end"* && "$out" == *"all done"* ]] || die "a record of the unit's output ended the client or was lost: '$out'"
log "ok: only the record from PID 1 ends the run"

require_user_namespaces
status=0
unshare -r "$REPO/bin/vekrona-update" now >/dev/null 2>"$work/err" || status=$?
[[ "$status" -ne 0 ]] && grep -q 'not root' "$work/err" || die "ran as root: $(cat "$work/err")"
log "ok: refuses to run as root"
