#!/usr/bin/env bash
set -euo pipefail

fail() { echo "agent-launch-check FAILED: $*" >&2; exit 1; }

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

command -v vekrona-agent >/dev/null 2>&1 || fail "vekrona-agent not on PATH"
command -v swaymsg >/dev/null 2>&1 || fail "swaymsg not on PATH"
command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"
[[ -n "${SWAYSOCK:-}" && -S "$SWAYSOCK" ]] || fail "SWAYSOCK not set to a live sway socket"
swaymsg -t get_version >/dev/null 2>&1 || fail "swaymsg get_version failed (no live sway session)"

AGENT_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
AGENT_CONFIG_FILE="$AGENT_CONFIG_HOME/vekrona/agent"
PREV_DEFAULT=""
[[ -f "$AGENT_CONFIG_FILE" ]] && PREV_DEFAULT="$(cat "$AGENT_CONFIG_FILE")"

STUB_DIR="$(mktemp -d)"

cleanup() {
  swaymsg -- '[app_id="vekrona.agent"] kill' >/dev/null 2>&1 || true
  if [[ -n "$PREV_DEFAULT" ]]; then
    printf '%s\n' "$PREV_DEFAULT" > "$AGENT_CONFIG_FILE"
  else
    rm -f "$AGENT_CONFIG_FILE"
  fi
  rm -rf "$STUB_DIR"
}
trap cleanup EXIT

vekrona-agent set claude || fail "vekrona-agent set claude failed"
[[ "$(vekrona-agent get)" == "claude" ]] || fail "vekrona-agent get did not return claude after set claude"

mapfile -t argv < <(vekrona-agent --dry-run)
[[ ${#argv[@]} -gt 0 ]] || fail "vekrona-agent --dry-run printed no argv"
printf '%s\n' "${argv[@]}" | grep -qx "ghostty" || fail "dry-run argv missing ghostty"
printf '%s\n' "${argv[@]}" | grep -qx -- "--class=vekrona.agent" || fail "dry-run argv missing --class=vekrona.agent"
printf '%s\n' "${argv[@]}" | grep -qx "claude" || fail "dry-run argv missing claude"
for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL OPENAI_API_KEY OPENAI_BASE_URL \
         CODEX_API_KEY GEMINI_API_KEY GOOGLE_API_KEY CURSOR_API_KEY OPENROUTER_API_KEY; do
  printf '%s\n' "${argv[@]}" | grep -qx "$v" || fail "dry-run argv missing stripped var: $v"
done

vekrona-agent set codex || fail "vekrona-agent set codex failed"
mapfile -t codex_argv < <(vekrona-agent --dry-run)
printf '%s\n' "${codex_argv[@]}" | grep -qx "check_for_update_on_startup=false" \
  || fail "codex recipe missing check_for_update_on_startup=false"
vekrona-agent set claude || fail "vekrona-agent set claude (restore) failed"

if vekrona-agent --error vekrona-agent-test-unknown-id --dry-run >/dev/null 2>"$STUB_DIR/error.err"; then
  fail "vekrona-agent --error with an unknown id unexpectedly succeeded"
fi
[[ -s "$STUB_DIR/error.err" ]] || fail "vekrona-agent --error with an unknown id produced no error message"

BIN_DIR="$STUB_DIR/bin"
mkdir -p "$BIN_DIR"
CAPTURE_FILE="$STUB_DIR/claude-capture"
cat > "$BIN_DIR/claude" <<STUB
#!/usr/bin/env bash
{
  printf 'ARGV:%s\n' "\$@"
  env
} > "$CAPTURE_FILE"
sleep 2
STUB
chmod +x "$BIN_DIR/claude"

found_marker="$STUB_DIR/window-found"

(
  timeout 15 swaymsg -t subscribe -m '["window"]' | while IFS= read -r _line; do
    if swaymsg -t get_tree | python3 -c '
import json, sys

data = json.load(sys.stdin)

def walk(node):
    if node.get("app_id") == "vekrona.agent":
        return True
    return any(walk(c) for c in node.get("nodes", []) + node.get("floating_nodes", []))

sys.exit(0 if walk(data) else 1)
'; then
      touch "$found_marker"
      break
    fi
  done
) &
watcher_pid=$!

PATH="$BIN_DIR:$PATH" ANTHROPIC_API_KEY=x ANTHROPIC_AUTH_TOKEN=y \
  vekrona-agent --prompt test || fail "vekrona-agent --prompt test failed to launch"

wait "$watcher_pid" || true
[[ -f "$found_marker" ]] || fail "no window with app_id vekrona.agent appeared within 15s"

deadline=$((SECONDS + 15))
while [[ ! -s "$CAPTURE_FILE" && $SECONDS -lt $deadline ]]; do
  inotifywait -qq -t 1 -e create,moved_to,close_write "$STUB_DIR" >/dev/null 2>&1 || true
done
[[ -s "$CAPTURE_FILE" ]] || fail "stub claude never wrote its capture file"

grep -qx "ARGV:test" "$CAPTURE_FILE" || fail "stub claude did not receive the prompt as its sole argv"
grep -q "^ANTHROPIC_API_KEY=" "$CAPTURE_FILE" && fail "ANTHROPIC_API_KEY leaked into the launched process environment"
grep -q "^ANTHROPIC_AUTH_TOKEN=" "$CAPTURE_FILE" && fail "ANTHROPIC_AUTH_TOKEN leaked into the launched process environment"

echo "agent-launch-check OK"
