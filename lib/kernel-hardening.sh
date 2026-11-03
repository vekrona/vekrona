#!/usr/bin/env bash
# etc/modprobe.d/vekrona-hardening.conf (the modules blocked) and etc/sysctl.d/60-vekrona.conf (vekrona's kernel sysctls: hardening and
# swap) are the only lists of what is blocked and set: stage 70-verify and tests/stages/test-kernel-hardening.sh read the names from them.

# The modules a modprobe.d file blocks, one per line.
blocked_modules() { awk '$1 == "install" { print $2 }' "$1"; }

# True when modprobe would run /bin/false instead of loading module $1, whether or not it is loaded now (-D, a dry run that
# ignores the loaded state). Further arguments go to modprobe (-C FILE).
module_blocked() {
  local module="$1" plan
  shift
  plan="$(modprobe "$@" -D "$module" 2>&1)" || return 1
  grep -qE '^install /bin/false[[:space:]]*$' <<<"$plan"
}

# The settings of a sysctl.d file, "key value" per line.
sysctl_settings() { sed -E -e '/^[[:space:]]*(#|$)/d' -e 's/[[:space:]]*=[[:space:]]*/ /' "$1"; }

# What the running kernel holds for the sysctl key $1, "name value" per line. A * in the key stands for each interface, so one key
# reads several values. A key that matches nothing ends the command.
sysctl_readings() {
  local pattern="/proc/sys/${1//.//}" path found=0
  for path in $pattern; do
    [[ -e "$path" ]] || break
    printf '%s %s\n' "${path#/proc/sys/}" "$(<"$path")"
    found=1
  done
  [[ $found -eq 1 ]] || die "the running kernel has no sysctl $1"
}
