#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export XDG_RUNTIME_DIR
XDG_RUNTIME_DIR="$(mktemp -d)"
trap 'rm -rf "$XDG_RUNTIME_DIR"' EXIT
source "$ROOT/iso/lib-vm.sh"
VM_LOCK_TIMEOUT_SEC=2

vm_lock
vm_unlock
vm_lock
vm_unlock

vm_lock
status=0
(vm_lock) 2>/dev/null || status=$?
[[ "$status" -ne 0 ]] || { echo "FAIL: a second process took the lock while it was held" >&2; exit 1; }
vm_unlock
(vm_lock) || { echo "FAIL: the lock was not released by vm_unlock" >&2; exit 1; }

echo "lock checks passed"
