#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"

ALL_STAGES=(00-repos 20-snapper 10-nvidia 15-mac 30-packages 40-system 45-auth 50-user 60-gaming 65-login-manager 70-verify 90a-switch-dm 90b-remove)

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
usage: $0 [--skip STAGE]... [--reset-dms-settings] [--list] [STAGE...]

Stages run in this order by default (those applicable to this hardware): ${DEFAULT_STAGES[*]}
Cleanup stages must be named explicitly: 90a-switch-dm 90b-remove
A STAGE may be given by its number (10), its name (nvidia) or the full name (10-nvidia).
--skip STAGE      omit a stage (also removes it from the set 70-verify checks)
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

skip=()
list_only=0
selected=()
export VEKRONA_RESET_DMS_SETTINGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip) [[ $# -ge 2 ]] || usage 1; skip+=("$(resolve_stage "$2")"); shift 2 ;;
    --reset-dms-settings) VEKRONA_RESET_DMS_SETTINGS=1; shift ;;
    --list) list_only=1; shift ;;
    -h|--help) usage ;;
    -*) usage 1 ;;
    *) selected+=("$(resolve_stage "$1")"); shift ;;
  esac
done
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
