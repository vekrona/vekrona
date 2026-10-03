#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# install.sh runs from a scratch tree whose only stage does nothing, so only its post-stage steps are exercised.
repo="$scratch/repo"
mkdir -p "$repo/lib" "$repo/stages" "$scratch/stubs" "$scratch/runtime" "$scratch/home"
cp "$ROOT/install.sh" "$repo/"
cp "$ROOT/lib/common.sh" "$repo/lib/"
echo 'exit 0' > "$repo/stages/50-user.sh"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$scratch/stubs/$1"; chmod +x "$scratch/stubs/$1"; }
stub sudo 'exit 0'
stub swaymsg 'echo "$@" >> "'"$scratch"'/swaymsg.log"; exit "$(cat "'"$scratch"'/swaymsg.status" 2>/dev/null || echo 0)"'
export PATH="$scratch/stubs:$PATH"
export HOME="$scratch/home" XDG_RUNTIME_DIR="$scratch/runtime"
export VEKRONA_ERROR_REPORTER=/usr/bin/true
unset SWAYSOCK

run_install() { rm -f "$scratch/swaymsg.log"; "$repo/install.sh" --no-pull 50-user >"$scratch/stdout" 2>"$scratch/stderr"; }
swaymsg_calls() { [[ -f "$scratch/swaymsg.log" ]] && wc -l < "$scratch/swaymsg.log" || echo 0; }

run_install || die "install without sway failed: $(cat "$scratch/stderr")"
[[ "$(swaymsg_calls)" -eq 0 ]] || die "swaymsg called with no sway session"
log "ok: no sway session, no reload"

bind_socket() { python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$XDG_RUNTIME_DIR/sway-ipc.1000.$1.sock"; }
true & dead_pid=$!
wait "$dead_pid"
bind_socket "$dead_pid"
run_install || die "install with only a crashed sway's socket failed: $(cat "$scratch/stderr")"
[[ "$(swaymsg_calls)" -eq 0 ]] || die "swaymsg called for a crashed sway's leftover socket"
log "ok: a crashed sway's leftover socket is not a running session"

bind_socket $$
run_install || die "install with a sway socket failed: $(cat "$scratch/stderr")"
[[ "$(swaymsg_calls)" -eq 1 ]] && grep -qx -- "-s $XDG_RUNTIME_DIR/sway-ipc.1000.$$.sock reload" "$scratch/swaymsg.log" \
  || die "install did not reload the live session found in XDG_RUNTIME_DIR exactly once: $(cat "$scratch/swaymsg.log" 2>&1)"
log "ok: a TTY or SSH install reloads the live session found by its socket, next to a crashed one's"

SWAYSOCK=/from/env run_install || die "install with SWAYSOCK failed: $(cat "$scratch/stderr")"
grep -qx -- '-s /from/env reload' "$scratch/swaymsg.log" || die "SWAYSOCK was not preferred: $(cat "$scratch/swaymsg.log")"
log "ok: a terminal inside sway reloads its own session"

echo 1 > "$scratch/swaymsg.status"
if run_install; then die "a failing swaymsg reload must fail install"; fi
grep -qF 'swaymsg reload failed' "$scratch/stderr" || die "error does not say the reload failed: $(cat "$scratch/stderr")"
log "ok: a failing reload fails install"
