#!/usr/bin/env bash
# The two files that shrink the kernel's attack surface (etc/modprobe.d/vekrona-hardening.conf, etc/sysctl.d/60-vekrona.conf) are
# the only list of what is blocked and set: stage 70-verify and tests/stages/test-kernel-hardening.sh read the names from them.

# The modules a modprobe.d file blocks, one per line.
blocked_modules() { awk '$1 == "install" { print $2 }' "$1"; }

# True when modprobe would run /bin/false instead of loading module $1. Further arguments go to modprobe (-C FILE).
module_blocked() {
  local module="$1" plan
  shift
  plan="$(modprobe "$@" -n -v "$module" 2>&1)" || return 1
  grep -qE '^install /bin/false[[:space:]]*$' <<<"$plan"
}

# The settings of a sysctl.d file, "key value" per line.
sysctl_settings() { sed -E -e '/^[[:space:]]*(#|$)/d' -e 's/[[:space:]]*=[[:space:]]*/ /' "$1"; }
