#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd rpm dnf5

ensure_repo_key claude-code
ensure_repo_key mise
ensure_root_file "$ROOT/etc/yum.repos.d/claude-code.repo" /etc/yum.repos.d/claude-code.repo
ensure_root_file "$ROOT/etc/yum.repos.d/mise.repo" /etc/yum.repos.d/mise.repo
ensure_repo_enabled "$CLAUDE_CODE_REPO_ID" "$MISE_REPO_ID"

ensure_pkg "${VEKRONA_AGENT_PKGS[@]}"
assert_npm_supports_release_age

ensure_root_file "$ROOT/etc/mise/config.toml" /etc/mise/config.toml
ensure_root_file "$ROOT/etc/profile.d/vekrona-mise.sh" /etc/profile.d/vekrona-mise.sh

ensure_root_file "$ROOT/etc/claude-code/managed-settings.json" /etc/claude-code/managed-settings.json
ensure_root_file "$ROOT/etc/codex/requirements.toml" /etc/codex/requirements.toml
ensure_root_file "$ROOT/etc/codex/managed_config.toml" /etc/codex/managed_config.toml
ensure_root_file "$ROOT/etc/opencode/opencode.json" /etc/opencode/opencode.json

log "mise system install"
mise_system_strict install
mise_system reshim

for t in claude "${VEKRONA_AGENT_TOOLS[@]}"; do
  bin="$(managed_binary "$t")"
  [[ -x "$bin" ]] || die "managed $t missing or not executable: $bin"
  log "$t: $("$bin" --version)"
done

for d in "$MISE_SYSTEM_DATA_DIR" "$MISE_SYSTEM_CONFIG_DIR"; do
  assert_tree_root_owned_not_writable "$d"
  assert "$d not writable by $VEKRONA_USER" bash -c "! touch '$d/.vekrona-write-test' 2>/dev/null"
done

log "agents ready: claude ${VEKRONA_AGENT_TOOLS[*]}"
