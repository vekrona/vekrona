#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

# timedatectl stub: the RTC mode lives in a file; `set-local-rtc 0` flips it unless RTC_STUCK is set.
cat > "$work/bin/timedatectl" <<'FAKE'
#!/usr/bin/env bash
echo "timedatectl $*" >> "$STUB_LOG"
case "$1" in
  show) cat "$RTC_FILE" ;;
  set-local-rtc) [[ -n "${RTC_STUCK-}" ]] || echo no > "$RTC_FILE" ;;
  *) exit 2 ;;
esac
FAKE
# sudo stub: logs the call; `-n true` succeeds only when SUDO_CACHED is set. Anything else is the interactive path.
cat > "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
echo "sudo $*" >> "$STUB_LOG"
if [[ "$1" == -n ]]; then [[ -n "${SUDO_CACHED-}" ]]; exit; fi
[[ "$1" == -v ]] && exit "${SUDO_V_STATUS:-0}"
exec "$@"
FAKE
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" RTC_FILE="$work/rtc"
: > "$STUB_LOG"

# --- ensure_utc_rtc ---

echo yes > "$RTC_FILE"
(ensure_utc_rtc) 2>/dev/null
grep -qx 'timedatectl set-local-rtc 0' "$STUB_LOG" || die "a local-time RTC was not switched to UTC"
[[ "$(<"$RTC_FILE")" == no ]] || die "the RTC is still local after ensure_utc_rtc"

: > "$STUB_LOG"
(ensure_utc_rtc) 2>/dev/null
! grep -q set-local-rtc "$STUB_LOG" || die "an RTC already in UTC was touched again"
log "ok: the RTC is switched to UTC once and left alone afterwards"

echo yes > "$RTC_FILE"
if (RTC_STUCK=1 ensure_utc_rtc) 2>/dev/null; then die "a failed switch to UTC was not reported"; fi
log "ok: an RTC that stays local is an error"

# --- sudo_refresh ---

skip_as_root "sudo_refresh is a no-op as root"

: > "$STUB_LOG"
(SUDO_CACHED=1 sudo_refresh </dev/null) 2>/dev/null
! grep -q 'sudo -v' "$STUB_LOG" || die "cached credentials still prompted"
log "ok: cached sudo credentials need no prompt"

# setsid drops the controlling terminal, as an SSH command or a service has none, even when stdin is /dev/null.
: > "$STUB_LOG"
status=0
setsid -w bash -c 'source "$1/tests/lib.sh"; sudo_refresh' _ "$ROOT" </dev/null 2>"$work/err" || status=$?
[[ "$status" -eq 1 ]] || die "sudo_refresh without a terminal must exit 1, got $status"
grep -q 'sudo needs a terminal' "$work/err" || die "no-terminal failure is not explained: $(cat "$work/err")"
! grep -q 'sudo -v' "$STUB_LOG" || die "sudo was invoked interactively without a terminal (logs a pam conversation failure)"
log "ok: without a terminal sudo_refresh dies before asking sudo anything"

# python's pty gives the child a controlling terminal as stdin; its exit status is the child's.
with_tty() { python3 -c 'import os, pty, sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@"; }
tty_status=0
SUDO_V_STATUS=1 with_tty bash -c 'source "$1/tests/lib.sh"; sudo_refresh' _ "$ROOT" >/dev/null 2>&1 || tty_status=$?
[[ "$tty_status" -eq 1 ]] || die "a refused sudo -v on a terminal must exit 1, got $tty_status"
grep -q 'sudo -v' "$STUB_LOG" || die "on a terminal sudo_refresh did not ask sudo"
log "ok: on a terminal a refused sudo is an error"

: > "$STUB_LOG"
with_tty bash -c 'source "$1/tests/lib.sh"; sudo_refresh </dev/null' _ "$ROOT" >/dev/null 2>&1 || true
grep -q 'sudo -v' "$STUB_LOG" || die "with a controlling terminal but redirected stdin sudo_refresh did not ask sudo"
log "ok: sudo is asked when a controlling terminal exists even if stdin is redirected"
