#!/usr/bin/env bash
set -euo pipefail

fail() { echo "agent-launch-check FAILED: $*" >&2; exit 1; }

# shellcheck source=vm/session-lib.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/session-lib.sh"

command -v vekrona-agent >/dev/null 2>&1 || fail "vekrona-agent not on PATH"
command -v vekrona-error >/dev/null 2>&1 || fail "vekrona-error not on PATH"
command -v swaymsg >/dev/null 2>&1 || fail "swaymsg not on PATH"
command -v inotifywait >/dev/null 2>&1 || fail "inotifywait not installed"
command -v timeout >/dev/null 2>&1 || fail "timeout not installed"
session_attach_existing \
  || fail "no live sway session found (expected session-check.sh to have brought one up already)"

AGENT_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
AGENT_CONFIG_FILE="$AGENT_CONFIG_HOME/vekrona/agent"
PREV_DEFAULT=""
[[ -f "$AGENT_CONFIG_FILE" ]] && PREV_DEFAULT="$(cat "$AGENT_CONFIG_FILE")"

STUB_DIR="$(mktemp -d)"

SCRIPT_ENV_VARS=(
  ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL OPENAI_API_KEY CODEX_API_KEY
  AZURE_OPENAI_API_KEY GROQ_API_KEY XAI_API_KEY MISTRAL_API_KEY DEEPSEEK_API_KEY
  CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX AWS_BEARER_TOKEN_BEDROCK
)
KEPT_ENV_VAR=VEKRONA_AGENT_CHECK_KEEP

cleanup() {
  swaymsg -- '[app_id="vekrona.agent"] kill' >/dev/null 2>&1 || true
  systemctl --user unset-environment "${SCRIPT_ENV_VARS[@]}" "$KEPT_ENV_VAR" >/dev/null 2>&1 || true
  if [[ -n "$PREV_DEFAULT" ]]; then
    printf '%s\n' "$PREV_DEFAULT" > "$AGENT_CONFIG_FILE"
  else
    rm -f "$AGENT_CONFIG_FILE"
  fi
  rm -rf "$STUB_DIR"
}
trap cleanup EXIT

argv_index_of() {
  local needle="$1" i
  shift
  for ((i = 1; i <= $#; i++)); do
    [[ "${!i}" == "$needle" ]] && { echo $((i - 1)); return 0; }
  done
  return 1
}

assert_unset_pair() {
  local var="$1" i
  shift
  for ((i = 1; i < $#; i++)); do
    if [[ "${!i}" == "-u" ]]; then
      local next=$((i + 1))
      [[ "${!next}" == "$var" ]] && return 0
    fi
  done
  return 1
}

open_watch() {
  local fd_var="$1" fd line
  shift
  exec {fd}< <(timeout 30 inotifywait -m "$@" 2>&1)
  while IFS= read -r -u "$fd" line; do
    if [[ "$line" == "Watches established." ]]; then
      printf -v "$fd_var" '%s' "$fd"
      return 0
    fi
  done
  fail "inotifywait never established its watch: $*"
}

assert_policy_file() {
  local file="$1" needle="$2"
  [[ -f "$file" ]] || fail "policy file missing: $file (stage 55-agents must install it)"
  [[ "$(stat -c %U "$file")" == "root" ]] || fail "policy file not owned by root: $file"
  grep -q -F -- "$needle" "$file" || fail "policy file $file does not contain: $needle"
}
assert_policy_file /etc/claude-code/managed-settings.json '"forceLoginMethod": "claudeai"'
assert_policy_file /etc/claude-code/managed-settings.json '"DISABLE_UPDATES"'
assert_policy_file /etc/codex/requirements.toml 'allowed_login_methods = ["chatgpt"]'
assert_policy_file /etc/codex/managed_config.toml 'check_for_update_on_startup = false'
assert_policy_file /etc/opencode/opencode.json '"autoupdate": false'

vekrona-agent set claude || fail "vekrona-agent set claude failed"
[[ "$(vekrona-agent get)" == "claude" ]] || fail "vekrona-agent get did not return claude after set claude"

if vekrona-agent set not-a-harness 2>/dev/null; then fail "vekrona-agent set accepted an unknown tool"; fi
[[ "$(vekrona-agent get)" == "claude" ]] || fail "a rejected 'set' changed the stored default"

systemctl --user set-environment "${SCRIPT_ENV_VARS[@]/%/=leak}" "$KEPT_ENV_VAR=keep" \
  || fail "systemctl --user set-environment failed"
manager_env="$(systemctl --user show-environment)"
for v in "${SCRIPT_ENV_VARS[@]}"; do
  grep -qx -- "$v=leak" <<<"$manager_env" || fail "test setup: $v is not in the user manager environment"
done

MANAGED_CLAUDE=/usr/bin/claude
SHIMS_DIR=/usr/local/share/mise/shims
AWKWARD_PROMPT=$'it\'s a "quoted" $(touch '"$STUB_DIR"$'/pwned) `touch '"$STUB_DIR"$'/pwned2` \\n\nsecond line; --flag *'

mapfile -d '' -t argv < <(vekrona-agent --prompt "$AWKWARD_PROMPT" --dry-run)
n=${#argv[@]}
[[ $n -gt 0 ]] || fail "vekrona-agent --dry-run printed no argv"
[[ "${argv[0]}" == "systemd-run" && "${argv[1]}" == "--user" ]] || fail "dry-run argv does not start with systemd-run --user: ${argv[0]} ${argv[1]}"
ghostty_at="$(argv_index_of ghostty "${argv[@]}")" || fail "dry-run argv missing ghostty"
[[ "${argv[ghostty_at + 1]}" == "--class=vekrona.agent" ]] || fail "ghostty is not followed by --class=vekrona.agent"
[[ "${argv[n - 3]}" == "$MANAGED_CLAUDE" ]] || fail "harness is not the absolute managed path $MANAGED_CLAUDE: ${argv[n - 3]}"
[[ "${argv[n - 2]}" == "--" ]] || fail "expected -- before the prompt, got: ${argv[n - 2]}"
[[ "${argv[n - 1]}" == "$AWKWARD_PROMPT" ]] || fail "the awkward prompt did not arrive as one unmodified argv element: ${argv[n - 1]}"
for v in "${SCRIPT_ENV_VARS[@]}"; do
  assert_unset_pair "$v" "${argv[@]}" || fail "dry-run argv has no 'env -u $v' although it is in the user manager environment"
done
if assert_unset_pair "$KEPT_ENV_VAR" "${argv[@]}"; then fail "unrelated variable $KEPT_ENV_VAR was stripped"; fi
path_line="$(printf '%s\n' "${argv[@]}" | grep '^--setenv=PATH=' || true)"
[[ "$path_line" == *"$SHIMS_DIR"* ]] || fail "--setenv=PATH does not carry $SHIMS_DIR: $path_line"

for tool_flag in "claude:--" "codex:--" "pi:--" "cursor-agent:--" "opencode:--prompt"; do
  t="${tool_flag%%:*}"
  expected_flag="${tool_flag##*:}"
  expected_bin="$SHIMS_DIR/$t"
  [[ "$t" == "claude" ]] && expected_bin="$MANAGED_CLAUDE"
  vekrona-agent set "$t" || fail "vekrona-agent set $t failed"
  mapfile -d '' -t tool_argv < <(vekrona-agent --prompt "leading-dash-check" --dry-run)
  m=${#tool_argv[@]}
  [[ "${tool_argv[m - 3]}" == "$expected_bin" ]] || fail "$t: harness is ${tool_argv[m - 3]}, expected $expected_bin"
  [[ "${tool_argv[m - 2]}" == "$expected_flag" ]] || fail "$t: expected '$expected_flag' before the prompt, got '${tool_argv[m - 2]}'"
  [[ "${tool_argv[m - 1]}" == "leading-dash-check" ]] || fail "$t: prompt was not the final argv element: ${tool_argv[m - 1]}"
done
vekrona-agent set claude || fail "vekrona-agent set claude (restore) failed"

if vekrona-agent --error vekrona-agent-test-unknown-id --dry-run >/dev/null 2>"$STUB_DIR/error.err"; then
  fail "vekrona-agent --error with an unknown id unexpectedly succeeded"
fi
[[ -s "$STUB_DIR/error.err" ]] || fail "vekrona-agent --error with an unknown id produced no error message"

ERROR_STORE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/vekrona/errors"
mkdir -p "$ERROR_STORE_DIR"
ERROR_MARKER="vekrona-agent-launch-check-$RANDOM$RANDOM"
open_watch ERROR_FD -r -e close_write,moved_to --format '%w%f' "$ERROR_STORE_DIR"
vekrona-error report --title "$ERROR_MARKER" --source manual || fail "vekrona-error report failed"
REAL_ERROR_ID=""
while IFS= read -r -u "$ERROR_FD" changed; do
  if [[ "$changed" == */record.json ]] && grep -q -F -- "$ERROR_MARKER" "$changed"; then
    REAL_ERROR_ID="$(basename "$(dirname "$changed")")"
    break
  fi
done
exec {ERROR_FD}<&-
[[ -n "$REAL_ERROR_ID" ]] || fail "vekrona-error report never wrote a record for the --error end-to-end test within 30s"

error_dry_run_output="$(vekrona-agent --error "$REAL_ERROR_ID" --dry-run | tr '\0' '\n')" \
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

PICKER_STUB_DIR="$STUB_DIR/picker-bin"
mkdir -p "$PICKER_STUB_DIR"
NOTIFY_LOG="$STUB_DIR/notify.log"
ROFI_ARGS="$STUB_DIR/rofi.args"
ROFI_STDIN="$STUB_DIR/rofi.stdin"
cat > "$PICKER_STUB_DIR/notify-send" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$NOTIFY_LOG"
STUB
cat > "$PICKER_STUB_DIR/rofi" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$ROFI_ARGS"
cat > "$ROFI_STDIN"
[[ -z "\${STUB_ROFI_CHOICE:-}" ]] || printf '%s\n' "\$STUB_ROFI_CHOICE"
exit "\${STUB_ROFI_STATUS:?}"
STUB
chmod +x "$PICKER_STUB_DIR/notify-send" "$PICKER_STUB_DIR/rofi"

with_picker() { PATH="$PICKER_STUB_DIR:$PATH" "$@"; }

rm -f "$AGENT_CONFIG_FILE"
for pick_argv in "--pick" "choose"; do
  : > "$NOTIFY_LOG"
  STUB_ROFI_STATUS=1 with_picker vekrona-agent "$pick_argv" >/dev/null 2>"$STUB_DIR/cancel.err" \
    || fail "cancelling the rofi picker (vekrona-agent $pick_argv) must exit 0"
  [[ ! -s "$STUB_DIR/cancel.err" ]] || fail "cancelling the rofi picker (vekrona-agent $pick_argv) printed an error: $(cat "$STUB_DIR/cancel.err")"
  [[ ! -s "$NOTIFY_LOG" ]] || fail "cancelling the rofi picker (vekrona-agent $pick_argv) raised a notification: $(cat "$NOTIFY_LOG")"
  [[ ! -e "$AGENT_CONFIG_FILE" ]] || fail "cancelling the rofi picker (vekrona-agent $pick_argv) wrote a default harness"
  grep -q -- "-no-custom" "$ROFI_ARGS" || fail "the picker runs rofi without -no-custom: $(cat "$ROFI_ARGS")"
  while IFS= read -r offered; do
    [[ -x "$([[ "$offered" == claude ]] && echo "$MANAGED_CLAUDE" || echo "$SHIMS_DIR/$offered")" ]] \
      || fail "the picker offers a harness that is not installed: $offered"
  done < "$ROFI_STDIN"

  if STUB_ROFI_STATUS=2 with_picker vekrona-agent "$pick_argv" >/dev/null 2>"$STUB_DIR/crash.err"; then
    fail "a crashing rofi picker (vekrona-agent $pick_argv) unexpectedly succeeded"
  fi
  grep -q "rofi exited with status 2" "$STUB_DIR/crash.err" || fail "a crashing rofi picker (vekrona-agent $pick_argv) was not reported: $(cat "$STUB_DIR/crash.err")"
  [[ ! -e "$AGENT_CONFIG_FILE" ]] || fail "a crashing rofi picker (vekrona-agent $pick_argv) wrote a default harness"
done

if STUB_ROFI_STATUS=0 STUB_ROFI_CHOICE="not a harness" with_picker vekrona-agent --pick >/dev/null 2>&1; then
  fail "a free-text picker answer unexpectedly launched something"
fi
[[ ! -e "$AGENT_CONFIG_FILE" ]] || fail "a free-text picker answer was persisted as the default harness"

printf 'not-a-harness\n' > "$AGENT_CONFIG_FILE"
: > "$NOTIFY_LOG"
STUB_ROFI_STATUS=1 with_picker vekrona-agent --pick >/dev/null 2>&1 \
  || fail "a stale stored default must fall back to the picker (cancel exits 0)"
grep -q "unknown or not installed" "$NOTIFY_LOG" || fail "a stale stored default fell back to the picker without a visible message"
[[ "$(cat "$AGENT_CONFIG_FILE")" == "not-a-harness" ]] || fail "cancelling the picker after a stale default changed the stored default"

STUB_ROFI_STATUS=0 STUB_ROFI_CHOICE=codex with_picker vekrona-agent --pick --dry-run >/dev/null \
  || fail "picking codex with --dry-run failed"
[[ "$(cat "$AGENT_CONFIG_FILE")" == "not-a-harness" ]] || fail "--dry-run persisted the picked harness"
rm -f "$AGENT_CONFIG_FILE"
vekrona-agent set claude || fail "vekrona-agent set claude (after picker checks) failed"

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

BIN_DIR="$STUB_DIR/bin"
mkdir -p "$BIN_DIR"
STUB_HARNESS="$BIN_DIR/claude"
STUB_ARGV_FILE="$STUB_DIR/stub.argv"
STUB_ENV_FILE="$STUB_DIR/stub.env"
cat > "$STUB_HARNESS" <<STUB
#!/usr/bin/env bash
printf '%s\0' "\$@" > "$STUB_ARGV_FILE.tmp"
env -0 > "$STUB_ENV_FILE.tmp"
mv "$STUB_ENV_FILE.tmp" "$STUB_ENV_FILE"
mv "$STUB_ARGV_FILE.tmp" "$STUB_ARGV_FILE"
exec tail -f /dev/null
STUB
chmod +x "$STUB_HARNESS"

mapfile -d '' -t launch_argv < <(vekrona-agent --prompt "$AWKWARD_PROMPT" --dry-run)
harness_at="$(argv_index_of "$MANAGED_CLAUDE" "${launch_argv[@]}")" || fail "dry-run argv does not contain $MANAGED_CLAUDE"
launch_argv[harness_at]="$STUB_HARNESS"

coproc WIN_WATCH { timeout 30 python3 "$STUB_DIR/sway-window-watch.py" "$SWAYSOCK" 2>&1; }
open_watch CAPTURE_FD -e moved_to --format '%f' "$STUB_DIR"

IFS= read -r -u "${WIN_WATCH[0]}" subscribe_reply
[[ "$subscribe_reply" == "SUBSCRIBED" ]] || fail "sway subscribe did not report success: $subscribe_reply"

"${launch_argv[@]}" >/dev/null || fail "launching the stub harness through the real systemd-run argv failed"

found=0
while IFS= read -r -u "${WIN_WATCH[0]}" _line; do
  if window_has_app_id; then
    found=1
    break
  fi
done
[[ "$found" == "1" ]] || fail "no window with app_id vekrona.agent appeared within 30s"

captured=0
while IFS= read -r -u "$CAPTURE_FD" moved; do
  if [[ "$moved" == "stub.argv" ]]; then captured=1; break; fi
done
exec {CAPTURE_FD}<&-
[[ "$captured" == "1" ]] || fail "the stub harness never wrote its capture within 30s"

mapfile -d '' -t stub_argv < "$STUB_ARGV_FILE"
[[ ${#stub_argv[@]} -eq 2 ]] || fail "the stub harness received ${#stub_argv[@]} arguments, expected exactly 2 (-- and the prompt)"
[[ "${stub_argv[0]}" == "--" ]] || fail "the stub harness did not receive -- first: ${stub_argv[0]}"
[[ "${stub_argv[1]}" == "$AWKWARD_PROMPT" ]] || fail "the prompt reached the harness modified (shell parsing between vekrona-agent, systemd-run, ghostty and env): ${stub_argv[1]}"
[[ ! -e "$STUB_DIR/pwned" && ! -e "$STUB_DIR/pwned2" ]] || fail "a command substitution inside the prompt was executed"

mapfile -d '' -t stub_env < "$STUB_ENV_FILE"
for v in "${SCRIPT_ENV_VARS[@]}"; do
  for entry in "${stub_env[@]}"; do
    [[ "$entry" != "$v="* ]] || fail "$v leaked into the launched harness environment although it was set in the user manager"
  done
done
printf '%s\n' "${stub_env[@]}" | grep -qx -- "$KEPT_ENV_VAR=keep" || fail "unrelated variable $KEPT_ENV_VAR was stripped from the harness environment"

echo "agent-launch-check OK"
