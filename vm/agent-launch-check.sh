#!/usr/bin/env bash
set -euo pipefail

fail() { echo "agent-launch-check FAILED: $*" >&2; exit 1; }

source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

command -v vekrona-agent >/dev/null 2>&1 || fail "vekrona-agent not on PATH"
command -v vekrona-error >/dev/null 2>&1 || fail "vekrona-error not on PATH"
command -v swaymsg >/dev/null 2>&1 || fail "swaymsg not on PATH"
command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"
session_attach_existing \
  || fail "no live sway session found (expected session-check.sh to have brought one up already)"

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

mapfile -t setenv_check_argv < <(vekrona-agent --dry-run)
setenv_path_line="$(printf '%s\n' "${setenv_check_argv[@]}" | grep '^--setenv=PATH=' || true)"
[[ -n "$setenv_path_line" ]] || fail "expected --setenv=PATH in dry-run argv (vekrona-agent must always pass a PATH carrying the mise shims dir, since the spawning systemd user manager's own environment may lack it)"
[[ "$setenv_path_line" == *"/usr/local/share/mise/shims"* ]] \
  || fail "--setenv=PATH in dry-run argv does not carry the mise shims dir: $setenv_path_line"

for tool_last2 in "claude:--" "codex:--" "pi:--" "cursor-agent:--" "opencode:--prompt"; do
  t="${tool_last2%%:*}"
  expect_second_to_last="${tool_last2##*:}"
  vekrona-agent set "$t" || fail "vekrona-agent set $t failed"
  mapfile -t prompt_argv < <(vekrona-agent --prompt "leading-dash-check" --dry-run)
  n=${#prompt_argv[@]}
  [[ "${prompt_argv[$((n - 2))]}" == "$expect_second_to_last" ]] \
    || fail "$t: expected '$expect_second_to_last' before the prompt, got '${prompt_argv[$((n - 2))]}'"
  [[ "${prompt_argv[$((n - 1))]}" == "leading-dash-check" ]] \
    || fail "$t: prompt was not the final argv element: ${prompt_argv[$((n - 1))]}"
done

vekrona-agent set claude || fail "vekrona-agent set claude (restore) failed"

if vekrona-agent --error vekrona-agent-test-unknown-id --dry-run >/dev/null 2>"$STUB_DIR/error.err"; then
  fail "vekrona-agent --error with an unknown id unexpectedly succeeded"
fi
[[ -s "$STUB_DIR/error.err" ]] || fail "vekrona-agent --error with an unknown id produced no error message"

ERROR_STORE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vekrona/errors"
ERROR_MARKER="vekrona-agent-launch-check-$RANDOM$RANDOM"
vekrona-error report --title "$ERROR_MARKER" --source manual || fail "vekrona-error report failed"

REAL_ERROR_ID=""
error_record_deadline=$((SECONDS + 30))
while [[ -z "$REAL_ERROR_ID" ]]; do
  REAL_ERROR_ID="$(grep -rl -F -- "$ERROR_MARKER" "$ERROR_STORE_DIR"/*/record.json 2>/dev/null \
    | head -1 | xargs -r dirname | xargs -r basename)"
  [[ -n "$REAL_ERROR_ID" ]] && break
  (( SECONDS < error_record_deadline )) || fail "vekrona-error report never produced a record for --error end-to-end test"
  inotifywait -qq -t 1 -e create,modify,moved_to,close_write "$ERROR_STORE_DIR" >/dev/null 2>&1 || true
done

error_dry_run_output="$(vekrona-agent --error "$REAL_ERROR_ID" --dry-run)" \
  || fail "vekrona-agent --error $REAL_ERROR_ID --dry-run failed"
[[ "$error_dry_run_output" == *"vekrona error $REAL_ERROR_ID"* ]] \
  || fail "vekrona-agent --error $REAL_ERROR_ID prompt did not include the error id (vekrona-error prompt not called correctly)"
[[ "$error_dry_run_output" == *"vekrona-diagnose"* ]] \
  || fail "vekrona-agent --error $REAL_ERROR_ID prompt did not mention the vekrona-diagnose skill"
error_skill_path="$(grep -oE '/[^ ]*/config/agents/skills/vekrona-diagnose/SKILL\.md' <<<"$error_dry_run_output" | head -1)"
[[ -n "$error_skill_path" ]] || fail "vekrona-agent --error $REAL_ERROR_ID prompt did not name a SKILL.md path"
[[ -f "$error_skill_path" ]] || fail "the skill path named in the --error prompt does not exist: $error_skill_path"
vekrona-error rm "$REAL_ERROR_ID" >/dev/null 2>&1 || true
echo "ok: vekrona-agent --error $REAL_ERROR_ID resolved its prompt via vekrona-error prompt, naming a real $error_skill_path"

BIN_DIR="$STUB_DIR/bin"
mkdir -p "$BIN_DIR"
CAPTURE_FILE="$STUB_DIR/claude-capture"
cat > "$BIN_DIR/claude" <<STUB
#!/usr/bin/env bash
{
  printf 'ARGV:%s\n' "\$*"
  env
} > "$CAPTURE_FILE"
sleep 2
STUB
chmod +x "$BIN_DIR/claude"

window_has_app_id() {
  swaymsg -t get_tree | python3 -c '
import json, sys

data = json.load(sys.stdin)

def walk(node):
    if node.get("app_id") == "vekrona.agent":
        return True
    return any(walk(c) for c in node.get("nodes", []) + node.get("floating_nodes", []))

sys.exit(0 if walk(data) else 1)
'
}

# swaymsg -t subscribe -m does not print sway's own "{\"success\": true}"
# subscribe-ack reply to stdout (verified: it only ever emits subsequent
# event frames), so the readiness signal here is read directly off the sway
# IPC socket instead of through swaymsg.
cat > "$STUB_DIR/sway-window-watch.py" <<'PYEOF'
import json
import socket
import struct
import sys

MAGIC = b"i3-ipc"
SUBSCRIBE = 2


def send_message(sock, msg_type, payload):
    data = payload.encode("utf-8")
    sock.sendall(MAGIC + struct.pack("<II", len(data), msg_type) + data)


def read_message(sock):
    header = b""
    while len(header) < 14:
        chunk = sock.recv(14 - len(header))
        if not chunk:
            raise EOFError("sway ipc socket closed while reading header")
        header += chunk
    if header[:6] != MAGIC:
        raise ValueError("bad sway ipc magic")
    length = struct.unpack("<I", header[6:10])[0]
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise EOFError("sway ipc socket closed while reading payload")
        payload += chunk
    return json.loads(payload.decode("utf-8"))


sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.connect(sys.argv[1])
send_message(sock, SUBSCRIBE, '["window"]')
reply = read_message(sock)
if reply.get("success") is not True:
    print(f"SUBSCRIBE_FAILED {reply}", flush=True)
    sys.exit(1)
print("SUBSCRIBED", flush=True)
while True:
    read_message(sock)
    print("EVENT", flush=True)
PYEOF

coproc WIN_WATCH { timeout 15 python3 "$STUB_DIR/sway-window-watch.py" "$SWAYSOCK" 2>&1; }

IFS= read -r -u "${WIN_WATCH[0]}" subscribe_reply
[[ "$subscribe_reply" == "SUBSCRIBED" ]] || fail "sway subscribe did not report success: $subscribe_reply"

PATH="$BIN_DIR:$PATH" ANTHROPIC_API_KEY=x ANTHROPIC_AUTH_TOKEN=y \
  vekrona-agent --prompt test || fail "vekrona-agent --prompt test failed to launch"

found=0
while IFS= read -r -u "${WIN_WATCH[0]}" _line; do
  if window_has_app_id; then
    found=1
    break
  fi
done
[[ "$found" == "1" ]] || fail "no window with app_id vekrona.agent appeared within 15s"

deadline=$((SECONDS + 15))
while [[ ! -s "$CAPTURE_FILE" && $SECONDS -lt $deadline ]]; do
  inotifywait -qq -t 1 -e create,moved_to,close_write "$STUB_DIR" >/dev/null 2>&1 || true
done
[[ -s "$CAPTURE_FILE" ]] || fail "stub claude never wrote its capture file"

grep -qx "ARGV:-- test" "$CAPTURE_FILE" || fail "stub claude did not receive -- before the prompt"
grep -q "^ANTHROPIC_API_KEY=" "$CAPTURE_FILE" && fail "ANTHROPIC_API_KEY leaked into the launched process environment"
grep -q "^ANTHROPIC_AUTH_TOKEN=" "$CAPTURE_FILE" && fail "ANTHROPIC_AUTH_TOKEN leaked into the launched process environment"

echo "agent-launch-check OK"
