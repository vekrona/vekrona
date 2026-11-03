#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

write_fake "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
# `systemctl show` answers with $FAKE_MAINPID, or fails; everything else is logged.
write_fake "$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
if [[ "$1" == show ]]; then
  [[ -z "${FAKE_SYSTEMCTL_FAIL:-}" ]] || { echo "systemctl: boom" >&2; exit 1; }
  echo "$FAKE_MAINPID"
  exit 0
fi
echo "systemctl $*" >> "$STUB_LOG"
FAKE
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" VEKRONA_SYSFS_ROOT="$work/root"
dropin_dir="$VEKRONA_SYSFS_ROOT/etc/systemd/system/NetworkManager-dispatcher.service.d"
dropin="$dropin_dir/vekrona-persist.conf"

# The dispatcher's process: pid 4242 with the given NUL-separated arguments; none means no such process.
set_process() {
  rm -rf "$VEKRONA_SYSFS_ROOT/proc"
  if (($# == 0)); then return 0; fi
  mkdir -p "$VEKRONA_SYSFS_ROOT/proc/4242"
  printf '%s\0' "$@" > "$VEKRONA_SYSFS_ROOT/proc/4242/cmdline"
}
set_dropin() { # present|absent
  rm -rf "$dropin_dir"
  if [[ "$1" == absent ]]; then return 0; fi
  mkdir -p "$dropin_dir"
  echo '[Service]' > "$dropin"
}
fresh_log() { : > "$STUB_LOG"; }
runs_persistent() { (nm_dispatcher_runs_persistent) 2>"$work/err"; }

export FAKE_MAINPID=4242

set_process /usr/libexec/nm-dispatcher --persist
runs_persistent || die "a dispatcher started with --persist was not reported"
log "ok: running with --persist is reported"

set_process /usr/libexec/nm-dispatcher
if runs_persistent; then die "a dispatcher started without --persist was reported"; fi
set_process /usr/libexec/nm-dispatcher --persistent /tmp/--persist
if runs_persistent; then die "an argument that only contains --persist was reported"; fi
log "ok: running without --persist is not reported"

set_process
if FAKE_MAINPID=0 runs_persistent; then die "a dispatcher that is not running (MainPID 0) was reported"; fi
if runs_persistent; then die "a dispatcher that exited since systemctl looked was reported"; fi
[[ ! -s "$work/err" ]] || die "a dispatcher that exited since systemctl looked was reported as an error: $(<"$work/err")"
log "ok: a dispatcher that is not running is not reported"

set_process /usr/libexec/nm-dispatcher --persist
rm "$VEKRONA_SYSFS_ROOT/proc/4242/cmdline"
ln -s "$work/nowhere" "$VEKRONA_SYSFS_ROOT/proc/4242/cmdline"
if runs_persistent; then die "a dispatcher whose command line cannot be read was reported as answered"; fi
grep -qF "cannot read $VEKRONA_SYSFS_ROOT/proc/4242/cmdline, the command line of nm-dispatcher (pid 4242), although the process exists" "$work/err" \
  || die "an unreadable command line of a running dispatcher was not an error: $(<"$work/err")"
log "ok: a command line that cannot be read while the process exists is an error"

if FAKE_SYSTEMCTL_FAIL=1 runs_persistent; then die "a failing systemctl show was read as an answer"; fi
grep -q 'systemctl show NetworkManager-dispatcher failed' "$work/err" || die "a failing systemctl show was not reported: $(<"$work/err")"
if FAKE_MAINPID=lizard runs_persistent; then die "a MainPID that is no number was read as an answer"; fi
log "ok: a systemctl that cannot answer is an error"

ensure() { (ensure_nm_dispatcher_not_persistent) 2>"$work/err" || die "ensure_nm_dispatcher_not_persistent failed: $(<"$work/err")"; }
restarted() { grep -qx 'systemctl try-restart NetworkManager-dispatcher.service' "$STUB_LOG"; }

set_dropin present
set_process /usr/libexec/nm-dispatcher --persist
fresh_log
ensure
[[ ! -e "$dropin" ]] || die "the drop-in was not removed"
[[ "$(<"$STUB_LOG")" == $'systemctl daemon-reload\nsystemctl try-restart NetworkManager-dispatcher.service' ]] || die "removing the drop-in did not reload and then restart the --persist dispatcher: $(<"$STUB_LOG")"
log "ok: removing the drop-in restarts a dispatcher running with --persist"

set_dropin absent
set_process /usr/libexec/nm-dispatcher --persist
fresh_log
ensure
restarted || die "a --persist dispatcher was left running because this run found no drop-in to remove: $(<"$STUB_LOG")"
log "ok: the drop-in an earlier run removed does not leave the --persist dispatcher running"

set_dropin present
set_process /usr/libexec/nm-dispatcher
fresh_log
ensure
[[ ! -e "$dropin" ]] || die "the drop-in was not removed"
if restarted; then die "a dispatcher without --persist was restarted: $(<"$STUB_LOG")"; fi
log "ok: a dispatcher without --persist is left alone"

set_process
fresh_log
FAKE_MAINPID=0 ensure
if restarted; then die "a dispatcher that is not running was restarted: $(<"$STUB_LOG")"; fi
log "ok: a dispatcher that is not running is left alone"

fresh_log
if (FAKE_SYSTEMCTL_FAIL=1 ensure_nm_dispatcher_not_persistent) 2>"$work/err"; then die "a failing systemctl show let the fix-up pass"; fi
if restarted; then die "a failing systemctl show still restarted the dispatcher"; fi
log "ok: a systemctl that cannot answer stops the fix-up"
