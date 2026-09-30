#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/lib/common.sh"

DEFAULT_STAGES=(00-repos 20-snapper 10-nvidia 30-packages 40-system 50-user 60-gaming 65-login-manager 70-verify)
ALL_STAGES=("${DEFAULT_STAGES[@]}" 90a-switch-dm 90b-remove)

usage() {
  cat <<EOF
usage: $0 [--skip STAGE]... [--reset-dms-settings] [STAGE...]

Stages run in this order by default: ${DEFAULT_STAGES[*]}
Cleanup stages must be named explicitly: 90a-switch-dm 90b-remove
A STAGE may be given by its number (10), its name (nvidia) or the full name (10-nvidia).
--skip STAGE      omit a stage (also removes it from the set 70-verify checks)
--reset-dms-settings  overwrite ~/.config/DankMaterialShell/settings.json from the seed
EOF
  exit "${1:-0}"
}

resolve_stage() {
  local want="$1" s
  for s in "${ALL_STAGES[@]}"; do
    [[ "$s" == "$want" || "${s%%-*}" == "$want" || "${s#*-}" == "$want" ]] && { echo "$s"; return 0; }
  done
  die "unknown stage: $want"
}

skip=()
selected=()
export VEKRONA_RESET_DMS_SETTINGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip) [[ $# -ge 2 ]] || usage 1; skip+=("$(resolve_stage "$2")"); shift 2 ;;
    --reset-dms-settings) VEKRONA_RESET_DMS_SETTINGS=1; shift ;;
    -h|--help) usage ;;
    -*) usage 1 ;;
    *) selected+=("$(resolve_stage "$1")"); shift ;;
  esac
done
[[ ${#selected[@]} -eq 0 ]] && selected=("${DEFAULT_STAGES[@]}")

run=()
for s in "${selected[@]}"; do
  skipped=0
  for k in "${skip[@]+"${skip[@]}"}"; do [[ "$k" == "$s" ]] && skipped=1; done
  [[ $skipped -eq 1 ]] || run+=("$s")
done
[[ ${#run[@]} -gt 0 ]] || die "nothing to run"

verify_scope=("${run[@]}")
if [[ ${#run[@]} -eq 1 && "${run[0]}" == "70-verify" ]]; then
  verify_scope=()
  for s in "${DEFAULT_STAGES[@]}"; do
    skipped=0
    for k in "${skip[@]+"${skip[@]}"}"; do [[ "$k" == "$s" ]] && skipped=1; done
    [[ $skipped -eq 1 ]] || verify_scope+=("$s")
  done
fi
export VEKRONA_STAGES="${verify_scope[*]}"
[[ $EUID -eq 0 ]] && die "run as your user, not root; stages call sudo where needed"

for s in "${run[@]}"; do
  log "=== stage $s ==="
  sudo_refresh
  bash "$ROOT/stages/$s.sh"
done
log "done: ${run[*]}"
