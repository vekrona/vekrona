#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# The stub models one user unit, old.service, with the files of $scratch/:
#   active    its ActiveState word, which is-active prints (status 0 for active, 3 otherwise);
#   enabled   present when is-enabled answers "enabled", otherwise "disabled" with status 1;
#   missing   present when the unit has no file at all: is-enabled prints nothing and exits 1, LoadState is not-found;
#   no-bus-for-enablement   present when is-enabled and `show -p LoadState` fail without output, as they do on an unreachable bus.
# `stop` and `disable` exit with the status in $scratch/<verb>.status (default 0). Every call is logged.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/stubs"
cat >"$scratch/stubs/systemctl" <<STUB
#!/bin/sh
echo "\$@" >>"$scratch/systemctl.log"
case " \$* " in
  *" is-active "*) cat "$scratch/active"; [ "\$(cat "$scratch/active")" = active ] || exit 3 ;;
  *" show -p LoadState "*)
    [ ! -e "$scratch/no-bus-for-enablement" ] || exit 1
    if [ -e "$scratch/missing" ]; then echo not-found; else echo loaded; fi ;;
  *" is-enabled "*)
    [ ! -e "$scratch/no-bus-for-enablement" ] || exit 1
    [ ! -e "$scratch/missing" ] || exit 1
    if [ -e "$scratch/enabled" ]; then echo enabled; else echo disabled; exit 1; fi ;;
  *" stop old.service "*) exit "\$(cat "$scratch/stop.status" 2>/dev/null || echo 0)" ;;
  *" disable old.service "*) exit "\$(cat "$scratch/disable.status" 2>/dev/null || echo 0)" ;;
esac
STUB
chmod +x "$scratch/stubs/systemctl"
export PATH="$scratch/stubs:$PATH"
calls() { grep -c -- " $1 old.service" "$scratch/systemctl.log" || true; }
reset() {
  : >"$scratch/systemctl.log"
  rm -f "$scratch/enabled" "$scratch/missing" "$scratch/no-bus-for-enablement" "$scratch/stop.status" "$scratch/disable.status"
  echo inactive >"$scratch/active"
}

reset
ensure_user_unit_stopped old.service
[[ "$(calls stop)" == 0 && "$(calls disable)" == 0 ]] || die "an inactive unit that is not enabled must be left alone"
log "ok: not enabled and not running, nothing to do"

reset
echo active >"$scratch/active"
touch "$scratch/enabled"
ensure_user_unit_stopped old.service
[[ "$(calls stop)" == 1 && "$(calls disable)" == 1 ]] || die "a running enabled unit must be stopped and disabled"
log "ok: a live unit is stopped and disabled"

reset
echo active >"$scratch/active"
touch "$scratch/missing"
ensure_user_unit_stopped old.service
[[ "$(calls stop)" == 1 && "$(calls disable)" == 0 ]] || die "a running unit whose file is gone must be stopped and not disabled"
log "ok: a running unit whose file is gone is stopped and not disabled"

reset
echo failed >"$scratch/active"
ensure_user_unit_stopped old.service
[[ "$(calls stop)" == 1 ]] || die "a failed unit must be stopped, so that its failed state clears"
log "ok: a unit in any state but inactive is stopped"

reset
touch "$scratch/enabled"
ensure_user_unit_stopped old.service
[[ "$(calls stop)" == 0 && "$(calls disable)" == 1 ]] || die "an inactive enabled unit must be disabled and not stopped"
log "ok: an inactive enabled unit is disabled only"

reset
echo active >"$scratch/active"
echo 1 >"$scratch/stop.status"
if (ensure_user_unit_stopped old.service) 2>/dev/null; then die "an old.service that cannot be stopped must fail"; fi
log "ok: a unit that will not stop fails the stage"

reset
touch "$scratch/enabled"
echo 1 >"$scratch/disable.status"
if (ensure_user_unit_stopped old.service) 2>/dev/null; then die "an old.service that cannot be disabled must fail"; fi
log "ok: a unit that will not disable fails the stage"

reset
touch "$scratch/no-bus-for-enablement"
if (ensure_user_unit_stopped old.service) 2>/dev/null; then die "a systemctl that cannot tell the unit's enablement must fail, not read as not enabled"; fi
[[ "$(calls disable)" == 0 ]] || die "a unit whose enablement is unknown was disabled"
log "ok: an is-enabled that fails without a missing unit to explain it is an error"

# retire_user_unit: HOME holds the unit's links; an unrelated unit's link stays.
HOME="$scratch/home"
units_dir="$HOME/.config/systemd/user"
mkdir -p "$units_dir/sway-session.target.wants" "$units_dir/timers.target.wants"
ln -s "$scratch/gone/old.service" "$units_dir/old.service"
ln -s "$units_dir/old.service" "$units_dir/sway-session.target.wants/old.service"
ln -s "$units_dir/old.service" "$units_dir/timers.target.wants/old.service"
ln -s "$units_dir/keep.service" "$units_dir/sway-session.target.wants/keep.service"

reset
echo active >"$scratch/active"
touch "$scratch/missing"
retire_user_unit old.service
[[ "$(calls stop)" == 1 ]] || die "retiring a running unit must stop it"
for leftover in "$units_dir/old.service" "$units_dir/sway-session.target.wants/old.service" "$units_dir/timers.target.wants/old.service"; do
  [[ ! -e "$leftover" && ! -L "$leftover" ]] || die "retiring old.service left $leftover"
done
[[ -L "$units_dir/sway-session.target.wants/keep.service" ]] || die "retiring old.service removed another unit's link"
log "ok: a retired unit is stopped and its unit file and every *.wants link, dangling or not, are removed"

reset
retire_user_unit old.service
log "ok: retiring a unit that is already gone succeeds"
