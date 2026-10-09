#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"

# Like the real /usr/sbin/akmods, a bash script: its process name is "akmods". It runs until released, then marks that it finished.
cat > "$work/bin/akmods" <<F
#!/usr/bin/env bash
echo running > "$work/started"
read -r < "$work/release"
echo finished > "$work/finished"
F
chmod +x "$work/bin/akmods"
mkfifo "$work/started" "$work/release"

wait_for_running_akmods
log "ok: returns at once when no akmods runs"

"$work/bin/akmods" &
read -r < "$work/started"

{
  wait_for_running_akmods
  if [[ -f "$work/finished" ]]; then echo waited > "$work/verdict"; else echo returned-early > "$work/verdict"; fi
} &
waiter=$!
until pgrep -P "$waiter" > /dev/null || ! kill -0 "$waiter" 2> /dev/null; do :; done
echo go > "$work/release"
wait "$waiter"
[[ "$(cat "$work/verdict")" == waited ]] || die "wait_for_running_akmods returned while akmods was still running"
log "ok: waits for a running akmods to exit"
