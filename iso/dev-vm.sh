#!/usr/bin/env bash
set -euo pipefail

ISO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib-vm.sh source-path=SCRIPTDIR
source "$ISO_DIR/lib-vm.sh"

DEFAULT_WAIT_TIMEOUT_SEC=600

usage() {
  cat <<'USAGE' >&2
usage: dev-vm.sh SUBCOMMAND [--name N] ...   (default name auth-1; ^[a-z0-9][a-z0-9-]{0,30}$)

Headless QEMU VM for agents. One VM of ours at a time; every VM dies with its
owner pid, its idle lease (re-armed by every subcommand) or its hard TTL.

  up [--profile installer|iso|disk] [--iso PATH] [--ram MB] [--vcpus N]
     [--fresh-disk] [--disk-size G] [--extra-disk G]... [--display none|gtk]
     [--owner-pid PID] [--ttl SEC] [--idle SEC] [--coexist FOREIGN_VM_NAME]...
     [--kernel-arg ARG]... (installer profile, appended to the kernel line) [--print]
  key KEY...                   one send-key per argument; chords like ctrl-alt-f2
  type [--enter] TEXT          type characters; [--print-keys] shows the key table, sends nothing
                               (a TEXT starting with a dash needs a preceding --)
  click X Y [--button left|right|middle] [--double]   pixel coordinates of a fresh screenshot
  shot ABSOLUTE_OUT.png        screenshot; prints the path
  ssh [-- CMD...]              ssh to the guest through the forwarded port
  wait serial=REGEX | ssh | exit [--timeout SEC]
                               serial: waits on the serial log (Python regex, also matches a prompt without trailing newline); exit: waits on the qemu pid;
                               ssh: no event source tells when guest sshd listens (user-mode port
                               forwarding accepts, then drops the connection, and ssh does not retry
                               that), so it retries whenever the guest writes to its serial console,
                               plus a slow backstop retry
  status | down | guard [--coexist NAME]... [--ram MB]
  sweep [--check] [--kill-ours]
USAGE
  exit "${1:-2}"
}

need_value() { [[ $# -ge 2 ]] || { vm_log "$1 needs a value"; usage; }; }

cmd_up() {
  local print_only=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) need_value "$@"; VM_PROFILE="$2"; shift 2 ;;
      --iso) need_value "$@"; VM_ISO="$2"; shift 2 ;;
      --ram) need_value "$@"; VM_RAM_MB="$2"; shift 2 ;;
      --vcpus) need_value "$@"; VM_VCPUS="$2"; shift 2 ;;
      --fresh-disk) VM_FRESH_DISK=1; shift ;;
      --disk-size) need_value "$@"; VM_DISK_GB="$2"; shift 2 ;;
      --extra-disk) need_value "$@"; VM_EXTRA_DISKS_GB+=("$2"); shift 2 ;;
      --display) need_value "$@"; VM_DISPLAY="$2"; shift 2 ;;
      --owner-pid) need_value "$@"; VM_OWNER_PID="$2"; shift 2 ;;
      --ttl) need_value "$@"; VM_TTL_SEC="$2"; shift 2 ;;
      --idle) need_value "$@"; VM_IDLE_SEC="$2"; shift 2 ;;
      --coexist) need_value "$@"; VM_COEXIST+=("$2"); shift 2 ;;
      --kernel-arg) need_value "$@"; VM_KERNEL_ARGS+=("$2"); shift 2 ;;
      --print) print_only=1; shift ;;
      -h|--help) usage 0 ;;
      *) vm_log "unknown option: $1"; usage ;;
    esac
  done
  if (( print_only )); then
    vm_validate_up_options
    vm_print_command
  else
    vm_up
  fi
}

cmd_key() {
  [[ $# -ge 1 ]] || usage
  vm_touch "$VM_NAME"
  vm_qmp "$VM_NAME" key "$@"
}

cmd_type() {
  local qmp_args=() print_keys=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --enter) qmp_args+=(--enter); shift ;;
      --print-keys) print_keys=1; qmp_args+=(--print-keys); shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [[ $# -eq 1 ]] || usage
  if (( print_keys )); then
    python3 -B "$VM_QMP_PY" type "${qmp_args[@]}" "$1"
  else
    vm_touch "$VM_NAME"
    vm_qmp "$VM_NAME" type "${qmp_args[@]}" "$1"
  fi
}

cmd_click() {
  [[ $# -ge 2 ]] || usage
  vm_touch "$VM_NAME"
  vm_qmp "$VM_NAME" click "$@"
}

cmd_shot() {
  [[ $# -eq 1 ]] || usage
  vm_touch "$VM_NAME"
  vm_qmp "$VM_NAME" shot "$1"
}

cmd_ssh() {
  [[ "${1:-}" != -- ]] || shift
  vm_touch "$VM_NAME"
  vm_ssh_command
  exec "${VM_SSH_COMMAND[@]}" "$@"
}

cmd_wait() {
  local what="${1:-}" timeout_sec="$DEFAULT_WAIT_TIMEOUT_SEC"
  [[ -n "$what" ]] || usage
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) need_value "$@"; timeout_sec="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  if [[ "$what" == exit ]] && ! vm_unit_loaded "$(vm_service "$VM_NAME")"; then
    return 0
  fi
  vm_touch "$VM_NAME" "$timeout_sec"
  case "$what" in
    serial=*) vm_wait_serial "${what#serial=}" "$timeout_sec" ;;
    ssh) vm_wait_ssh "$timeout_sec" ;;
    exit) vm_wait_exit "$timeout_sec" ;;
    *) usage ;;
  esac
}

cmd_status() {
  local unit variable
  vm_load_meta "$VM_NAME"
  unit="$(vm_service "$VM_NAME")"
  for variable in ${!META_*}; do
    printf '%s=%s\n' "$variable" "${!variable}"
  done
  systemctl --user show "$unit" -p ActiveState -p MemoryCurrent -p MemoryMax
  systemctl --user list-timers --no-legend "$(vm_idle_timer "$VM_NAME")"
}

cmd_down() {
  [[ $# -eq 0 ]] || usage
  vm_down "$VM_NAME"
}

cmd_guard() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --coexist) need_value "$@"; VM_COEXIST+=("$2"); shift 2 ;;
      --ram) need_value "$@"; VM_RAM_MB="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  vm_guard "$VM_RAM_MB" "${VM_COEXIST[@]}"
  vm_log "guard passed: a VM with ${VM_RAM_MB} MB may start"
}

cmd_sweep() {
  local check=0 kill_ours=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) check=1; shift ;;
      --kill-ours) kill_ours=1; shift ;;
      *) usage ;;
    esac
  done
  if (( kill_ours )); then
    vm_kill_ours
  elif (( check )); then
    if vm_has_ours; then
      vm_print_ours
      exit 1
    fi
  else
    vm_print_ours
    vm_print_foreign
  fi
}

main() {
  local args=() subcommand
  VM_ARGV="$(printf '%q ' "$@")"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) need_value "$@"; VM_NAME="$2"; shift 2 ;;
      --) args+=("$@"); break ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
  [[ $# -ge 1 ]] || usage
  subcommand="$1"
  shift
  case "$subcommand" in
    -h|--help|help) usage 0 ;;
    up|key|type|click|shot|ssh|wait|status|down|guard|sweep) ;;
    *) vm_log "unknown subcommand: $subcommand"; usage ;;
  esac
  [[ "$subcommand" == sweep ]] || [[ "$subcommand" == type && "${1:-}" == --print-keys ]] || vm_require_name "$VM_NAME"
  "cmd_$subcommand" "$@"
}

main "$@"
