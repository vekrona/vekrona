#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
settings="$ROOT/etc/claude-code/managed-settings.json"

python3 -m json.tool "$settings" >/dev/null || die "$settings is not valid JSON"

[[ "$(jq -r .forceLoginMethod "$settings")" == claudeai ]] || die "Claude Code must accept only a subscription login"
[[ "$(jq -r .permissions.disableBypassPermissionsMode "$settings")" == disable ]] \
  || die "bypass-permissions mode must be off: --dangerously-skip-permissions would run an injected prompt unchecked"
log "ok: managed settings force the subscription login and switch bypass-permissions mode off"

denied() { jq -e --arg rule "$1" '.permissions.deny | index($rule) != null' "$settings" >/dev/null; }
for rule in 'Read(~/.ssh/**)' 'Read(~/.gnupg/**)' 'Read(~/.local/share/keyrings/**)' 'Read(~/.config/vdirsyncer/config)' \
  'Read(~/.claude/.credentials.json)' 'Read(~/.codex/auth.json)' 'Read(~/.local/state/syncthing/config.xml)' \
  'Read(~/.local/state/vekrona/syncthing-gui-password)'; do
  denied "$rule" || die "the secret is not denied: $rule"
done
log "ok: the secrets the repo knows about are denied"

# A bare "/path" anchors at the settings file, not at the filesystem, so such a rule would guard nothing.
bad="$(jq -r '.permissions.deny[] | select(test("^(Read|Edit)\\((~/|//)") | not)' "$settings")"
[[ -z "$bad" ]] || die "deny rules must be anchored with ~/ or //: $bad"
log "ok: every deny rule is anchored at the home directory or the filesystem root"
