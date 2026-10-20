#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
akmods_pid=""
# A failed run leaves the fake akmods blocked on its fifo; killing it fails when it already exited, which is fine.
cleanup() { [[ -z "$akmods_pid" ]] || kill "$akmods_pid" 2> /dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
mkdir "$work/bin"

# Like the real /usr/sbin/akmods, a bash script with a direct shebang: the kernel names such a process after the script
# ("akmods"), while one started through `env bash` is named "bash" and pidwait never sees it. It runs until released,
# then marks that it finished.
cat > "$work/bin/akmods" <<F
#!/usr/bin/bash
echo running > "$work/started"
read -r < "$work/release"
echo finished > "$work/finished"
F
chmod +x "$work/bin/akmods"
mkfifo "$work/started" "$work/release"

wait_for_running_akmods
log "ok: returns at once when no akmods runs"

"$work/bin/akmods" &
akmods_pid=$!
read -r < "$work/started"

{
  PATH="$work/bin:$PATH" wait_for_running_akmods
  if [[ -f "$work/finished" ]]; then echo waited > "$work/verdict"; else echo returned-early > "$work/verdict"; fi
} &
waiter=$!
# The real pidwait, a child of the waiter's timeout, is what blocks while akmods runs: release akmods only once it exists.
waiter_is_in_pidwait() {
  local timeout_pid
  timeout_pid="$(pgrep -x -P "$waiter" timeout)" || return 1
  pgrep -x -P "$timeout_pid" pidwait > /dev/null
}
# Back-to-back looks, but bounded: a waiter that gets to neither must fail the test.
waiter_waits_or_ended() { waiter_is_in_pidwait || ! kill -0 "$waiter" 2> /dev/null; }
wait_until 30 waiter_waits_or_ended || die "the waiter neither waited for akmods nor ended within 30 s"
kill -0 "$waiter" 2> /dev/null || die "the waiter ended before it waited for akmods"
echo go > "$work/release"
wait "$waiter"
[[ "$(cat "$work/verdict")" == waited ]] || die "wait_for_running_akmods returned while akmods was still running"
log "ok: waits for a running akmods to exit"
