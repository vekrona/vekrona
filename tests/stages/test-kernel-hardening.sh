#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/lib/kernel-hardening.sh"

modprobe_conf="$ROOT/etc/modprobe.d/vekrona-hardening.conf"
sysctl_conf="$ROOT/etc/sysctl.d/60-vekrona.conf"

modules="$(blocked_modules "$modprobe_conf")"
[[ -n "$modules" ]] || die "$modprobe_conf blocks no module"
for module in $modules; do
  module_blocked "$module" -C "$modprobe_conf" || die "modprobe does not run /bin/false for $module with $modprobe_conf"
  # A module the kernel does not ship, or has built in, makes its line dead: nothing can load it anyway.
  path="$(modinfo -k "$(uname -r)" -n "$module")" || die "the running kernel does not ship the module $module: drop its line"
  [[ "$path" != "(builtin)" ]] || die "$module is built into the kernel, so blocking it does nothing: block the modules it loads instead"
done
log "ok: every blocked module is shipped by the running kernel as a module, and modprobe runs /bin/false for it"

! module_blocked lizard -C "$modprobe_conf" || die "a module the file does not name must not read as blocked"
log "ok: a module that is not listed is not blocked"

settings="$(sysctl_settings "$sysctl_conf")"
[[ -n "$settings" ]] || die "$sysctl_conf sets nothing"
while read -r key value; do
  [[ -n "$value" ]] || die "the setting $key in $sysctl_conf has no value"
  sysctl -N -- "$key" >/dev/null || die "the running kernel has no sysctl $key: systemd-sysctl would fail on it"
done <<<"$settings"
log "ok: every sysctl key in the file exists in the running kernel"
