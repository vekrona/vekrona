#!/usr/bin/env bash
set -euo pipefail

fail() { echo "agents-check FAILED: $*" >&2; exit 1; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

for t in "${VEKRONA_AGENT_TOOLS[@]}"; do
  bin="$(managed_binary "$t")"
  [[ -x "$bin" ]] || fail "$t shim missing or not executable: $bin"
  version="$("$bin" --version 2>&1)" || fail "$t --version failed: $version"
  echo "agents-check: $t -> $bin ($version)"
done

version="$(claude --version 2>&1)" || fail "claude --version failed: $version"
echo "agents-check: claude -> $(command -v claude) ($version)"

resolves_in_login_shell() { bash -lc "command -v $1" >/dev/null 2>&1; }
for t in claude codex pi opencode cursor-agent; do
  resolves_in_login_shell "$t" \
    || fail "$t does not resolve on PATH in a login shell (check /etc/profile.d/vekrona-mise.sh)"
done
echo "agents-check: all harnesses resolve on PATH in a login shell"

owner_pkg="$(rpm -qf /usr/bin/claude 2>/dev/null || true)"
[[ "$owner_pkg" == claude-code-* ]] || fail "/usr/bin/claude is not owned by claude-code: $owner_pkg"

sig="$(rpm -q --qf '%{RSAHEADER:pgpsig}\n' claude-code 2>/dev/null || true)"
keyid="$(grep -oE 'Key ID [0-9A-Fa-f]+' <<<"$sig" | awk '{print tolower($3)}')"
[[ "${keyid: -8}" == "1a7ecace" ]] || fail "claude-code signature key id mismatch: $sig"
echo "agents-check: claude-code signed by key id ...${keyid: -8}"

for d in "$MISE_SYSTEM_DATA_DIR" "$MISE_SYSTEM_CONFIG_DIR"; do
  touch "$d/.agents-check-write-test" 2>/dev/null && fail "writing into $d succeeded, expected Permission denied"
done
echo "agents-check: mise system dirs are not writable by $(id -un)"

npm_version="$(npm --version)" || fail "npm --version failed"
version_at_least "$npm_version" "$MISE_NPM_MIN_RELEASE_AGE_VERSION" \
  || fail "npm $npm_version is older than $MISE_NPM_MIN_RELEASE_AGE_VERSION"
echo "agents-check: npm $npm_version supports minimum_release_age"

for repo in "${!VEKRONA_REPO_KEY_FINGERPRINTS[@]}"; do
  fingerprint="$(tr '[:upper:]' '[:lower:]' <<<"${VEKRONA_REPO_KEY_FINGERPRINTS[$repo]}")"
  rpm -q gpg-pubkey --qf '%{VERSION}\n' | grep -qx "$fingerprint" \
    || fail "rpm keyring lacks the pinned key for $repo ($fingerprint)"
  key_file="$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$repo")"
  [[ "$(stat -c '%U %a' "$key_file")" == "root 644" ]] || fail "$key_file is not root-owned 0644: $(stat -c '%U %a' "$key_file")"
done
echo "agents-check: pinned repo keys are in the rpm keyring and vendored files are root-owned 0644"

for repo_file in claude-code mise 1password; do
  grep -qx "gpgkey=file://$VEKRONA_REPO_KEY_DIR/$(repo_key_name "$repo_file")" "/etc/yum.repos.d/$repo_file.repo" \
    || fail "/etc/yum.repos.d/$repo_file.repo does not use the vendored key through gpgkey=file://"
done
echo "agents-check: repo files take their keys from file://"

mise_list="$(mise_system ls)" || fail "mise ls failed"
for t in "${VEKRONA_AGENT_TOOLS[@]}"; do
  grep -q "$t" <<<"$mise_list" || fail "mise ls does not list $t: $mise_list"
done
echo "agents-check: mise lists all agent tools"

json_policy_value() { jq -er "$2" "$1" || fail "$1 lacks $2"; }
[[ "$(json_policy_value /etc/claude-code/managed-settings.json .forceLoginMethod)" == claudeai ]] \
  || fail "claude managed settings do not force claudeai login"
[[ "$(json_policy_value /etc/claude-code/managed-settings.json .env.DISABLE_AUTOUPDATER)" == 1 ]] \
  || fail "claude managed settings do not disable the auto-updater"
[[ "$(json_policy_value /etc/opencode/opencode.json .autoupdate)" == false ]] \
  || fail "opencode config does not disable autoupdate"
grep -qxF 'allowed_login_methods = ["chatgpt"]' /etc/codex/requirements.toml \
  || fail "codex requirements do not restrict login to chatgpt"
grep -qxF 'check_for_update_on_startup = false' /etc/codex/managed_config.toml \
  || fail "codex managed config does not turn the update check off"
echo "agents-check: harness policy files carry the subscription-only and no-update keys"

snapper_numbers() { sudo snapper -c root --csvout --no-headers list --columns number; }

vekrona_update_bin="$(command -v vekrona-update || true)"
[[ -n "$vekrona_update_bin" ]] || vekrona_update_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/vekrona-update"
[[ -x "$vekrona_update_bin" ]] || fail "vekrona-update not found (looked on PATH and at $vekrona_update_bin)"

before_count="$(snapper_numbers | wc -l)"
update_output="$(mktemp)"
trap 'rm -f "$update_output"' EXIT
"$vekrona_update_bin" 2>&1 | tee "$update_output"
! grep -q 'minimum_release_age is set for' "$update_output" \
  || fail "vekrona-update reported that mise cannot apply minimum_release_age"
after_count="$(snapper_numbers | wc -l)"

new_count=$((after_count - before_count))
[[ "$new_count" -ge 2 ]] || fail "expected at least 2 new snapper snapshots from vekrona-update, got $new_count"
echo "agents-check: vekrona-update produced $new_count new snapshot(s)"

echo "agents-check OK"
