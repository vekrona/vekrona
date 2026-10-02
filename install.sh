#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"

ALL_STAGES=(00-repos 20-snapper 10-nvidia 15-mac 30-packages 40-system 45-auth 50-user 55-agents 60-gaming 65-login-manager 70-verify 90a-switch-dm 90b-remove)

array_has() {
  local needle="$1" item
  shift
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

without_skipped() {
  local item
  for item in "$@"; do
    array_has "$item" "${skip[@]+"${skip[@]}"}" || printf '%s\n' "$item"
  done
}

applicable_default_stages() {
  local stage
  for stage in "${ALL_STAGES[@]}"; do
    [[ "$stage" == 90* ]] && continue
    if stage_applies "$stage"; then printf '%s\n' "$stage"; fi
  done
}

mapfile -t DEFAULT_STAGES < <(applicable_default_stages)

usage() {
  cat <<EOF
usage: $0 [--skip STAGE]... [--reset-dms-settings] [--no-pull] [--list] [STAGE...]

Stages run in this order by default (those applicable to this hardware): ${DEFAULT_STAGES[*]}
Cleanup stages must be named explicitly: 90a-switch-dm 90b-remove
A STAGE may be given by its number (10), its name (nvidia) or the full name (10-nvidia).
--skip STAGE      omit a stage (also removes it from the set 70-verify checks)
--no-pull         do not clone or update the system copy ($VEKRONA_SYSTEM_ROOT) nor re-run from it
--list            print the resolved stages, one per line, and exit
--reset-dms-settings  overwrite ~/.config/DankMaterialShell/settings.json from the seed
EOF
  exit "${1:-0}"
}

resolve_stage() {
  local want="$1" stage
  for stage in "${ALL_STAGES[@]}"; do
    [[ "$stage" == "$want" || "${stage%%-*}" == "$want" || "${stage#*-}" == "$want" ]] && { echo "$stage"; return 0; }
  done
  die "unknown stage: $want"
}

orig_args=("$@") # the parse loop shifts them away; the re-exec below needs them
skip=()
list_only=0
no_pull=0
selected=()
export VEKRONA_RESET_DMS_SETTINGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip) [[ $# -ge 2 ]] || usage 1; skip+=("$(resolve_stage "$2")"); shift 2 ;;
    --reset-dms-settings) VEKRONA_RESET_DMS_SETTINGS=1; shift ;;
    --list) list_only=1; shift ;;
    --no-pull) no_pull=1; shift ;;
    -h|--help) usage ;;
    -*) usage 1 ;;
    *) selected+=("$(resolve_stage "$1")"); shift ;;
  esac
done
# Stages always run from the system copy, a separate clone that is kept current. --no-pull is for callers that
# provide the tree themselves (ISO firstboot, the VM harness, a dev checkout); --list never touches the network.
sync_system_copy() {
  local before after upstream_ok=1 out
  require_cmd git
  if [[ ! -e "$VEKRONA_SYSTEM_ROOT" ]]; then
    log "cloning $VEKRONA_REPO_URL to $VEKRONA_SYSTEM_ROOT"
    mkdir -p "$(dirname "$VEKRONA_SYSTEM_ROOT")"
    git clone "$VEKRONA_REPO_URL" "$VEKRONA_SYSTEM_ROOT" || die "git clone failed: $VEKRONA_REPO_URL"
  else
    git -C "$VEKRONA_SYSTEM_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
      || die "$VEKRONA_SYSTEM_ROOT exists but is not a git checkout; move it away and rerun"
    out="$(git -C "$VEKRONA_SYSTEM_ROOT" status --porcelain)" || die "git status failed in $VEKRONA_SYSTEM_ROOT"
    [[ -z "$out" ]] || die "$VEKRONA_SYSTEM_ROOT has local changes, commit or discard them (edit a dev checkout and run it with --no-pull instead): ${out//$'\n'/ | }"
    before="$(git -C "$VEKRONA_SYSTEM_ROOT" rev-parse HEAD)"
    log "updating $VEKRONA_SYSTEM_ROOT"
    # Fetch and merge separately: only the fetch may fail for network reasons; a non-fast-forward must stop the run.
    if git -C "$VEKRONA_SYSTEM_ROOT" fetch --quiet; then
      git -C "$VEKRONA_SYSTEM_ROOT" merge --ff-only --quiet '@{u}' \
        || die "cannot fast-forward $VEKRONA_SYSTEM_ROOT (diverged or no upstream); resolve it by hand"
    else
      upstream_ok=0
      warn "git fetch failed (network?), continuing with the current commit of $VEKRONA_SYSTEM_ROOT"
    fi
    after="$(git -C "$VEKRONA_SYSTEM_ROOT" rev-parse HEAD)"
    [[ "$before" == "$after" ]] || log "system copy moved ${before:0:9} -> ${after:0:9}"
    [[ $upstream_ok -eq 1 ]] && log "system copy is at ${after:0:9}"
  fi
  if [[ "$(cd "$ROOT" && pwd -P)" != "$(cd "$VEKRONA_SYSTEM_ROOT" && pwd -P)" || "${before:-}" != "${after:-}" ]]; then
    log "re-running from the system copy: $VEKRONA_SYSTEM_ROOT"
    VEKRONA_SYNCED=1 exec "$VEKRONA_SYSTEM_ROOT/install.sh" "${orig_args[@]+"${orig_args[@]}"}"
  fi
}

if [[ $no_pull -eq 0 && $list_only -eq 0 && "${VEKRONA_SYNCED:-0}" != 1 ]]; then
  sync_system_copy
fi
if [[ $list_only -eq 0 ]]; then
  log "stages run from $(cd "$ROOT" && pwd -P)$([[ $no_pull -eq 1 ]] && echo ' (--no-pull)')"
fi

if [[ $list_only -eq 0 ]] && ! array_has 10-nvidia "${skip[@]+"${skip[@]}"}" \
  && { [[ ${#selected[@]} -eq 0 ]] || array_has 10-nvidia "${selected[@]}"; }; then
  warn_if_nvidia_stage_refused
fi
if [[ ${#selected[@]} -eq 0 ]]; then
  selected=("${DEFAULT_STAGES[@]}")
else
  for stage in "${selected[@]}"; do
    stage_applies "$stage" || die "stage $stage does not apply to this hardware"
  done
fi

mapfile -t run < <(without_skipped "${selected[@]}")
[[ ${#run[@]} -gt 0 ]] || die "nothing to run (every selected stage was skipped)"

verify_scope=("${run[@]}")
if [[ ${#run[@]} -eq 1 && "${run[0]}" == "70-verify" ]]; then
  mapfile -t verify_scope < <(without_skipped "${DEFAULT_STAGES[@]}")
fi
export VEKRONA_STAGES="${verify_scope[*]}"
if [[ $list_only -eq 1 ]]; then printf '%s\n' "${run[@]}"; exit 0; fi
[[ $EUID -eq 0 ]] && die "run as your user, not root; stages call sudo where needed"

for stage in "${run[@]}"; do
  log "=== stage $stage ==="
  sudo_refresh
  bash "$ROOT/stages/$stage.sh"
done
log "done: ${run[*]}"
