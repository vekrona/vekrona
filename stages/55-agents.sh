#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/lib/common.sh"

require_cmd rpm curl gpg dnf5

ensure_root_file "$ROOT/etc/yum.repos.d/claude-code.repo" /etc/yum.repos.d/claude-code.repo
ensure_root_file "$ROOT/etc/yum.repos.d/mise.repo" /etc/yum.repos.d/mise.repo
ensure_repo_enabled "$CLAUDE_CODE_REPO_ID" "$MISE_REPO_ID"

ensure_gpg_key_imported "$CLAUDE_CODE_GPG_URL" "$CLAUDE_CODE_GPG_FINGERPRINT"
ensure_gpg_key_imported "$MISE_GPG_URL" "$MISE_GPG_FINGERPRINT"

ensure_pkg "${VEKRONA_AGENT_PKGS[@]}"

ensure_root_file "$ROOT/etc/mise/config.toml" /etc/mise/config.toml
ensure_root_file "$ROOT/etc/profile.d/vekrona-mise.sh" /etc/profile.d/vekrona-mise.sh

log "mise system install"
mise_system install
mise_system reshim

for t in "${VEKRONA_AGENT_TOOLS[@]}"; do
  bin="$MISE_SYSTEM_DATA_DIR/shims/$t"
  [[ -x "$bin" ]] || die "agent shim missing or not executable: $bin"
  log "$t: $("$bin" --version)"
done

assert "claude resolves" bash -c "command -v claude >/dev/null"
log "claude: $(claude --version)"

for d in "$MISE_SYSTEM_DATA_DIR" "$MISE_SYSTEM_CONFIG_DIR"; do
  assert "$d owned by root" owned_by "$d" root
  assert "$d not writable by $VEKRONA_USER" bash -c "! touch '$d/.vekrona-write-test' 2>/dev/null"
done

for name in claude "${VEKRONA_AGENT_TOOLS[@]}"; do
  shadow="$HOME/.local/bin/$name"
  [[ -e "$shadow" ]] && warn "user-local copy shadows the managed binary on PATH: $shadow (remove it so '$name' resolves to the vekrona-managed install)"
done

log "agents ready: claude ${VEKRONA_AGENT_TOOLS[*]}"
