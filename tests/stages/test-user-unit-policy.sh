#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
units="$ROOT/config/systemd-user"

# A unit that treats exit 1 as a clean stop must still restart on an early exit; only the start limit may fail it.
for unit in "$units"/*.service; do
  grep -qE '^SuccessExitStatus=.*\b1\b' "$unit" || continue
  grep -qx 'Restart=always' "$unit" || die "$(basename "$unit") counts exit 1 as success, so only Restart=always still notices a start that dies at once"
done
log "ok: a unit that accepts exit 1 restarts on every exit"

# The units the session cannot do without keep restarting however often they fail, with a delay that grows to a minute so
# that a crash loop does not spin. Each failed exit still logs "Failed with result", which reaches the error pipeline.
for unit in vekrona-shell vekrona-idle vekrona-app-switch vekrona-cliphist; do
  grep -qx 'StartLimitIntervalSec=0' "$units/$unit.service" || die "$unit.service gives up after the default start limit, and the session loses it for good"
  grep -qE '^RestartSec=[1-9]' "$units/$unit.service" || die "$unit.service restarts with no pause, which spins a crash loop"
  grep -qE '^RestartSteps=[1-9]' "$units/$unit.service" || die "$unit.service restarts at a fixed rate: a crash loop never backs off"
  grep -qx 'RestartMaxDelaySec=60' "$units/$unit.service" || die "$unit.service must back off to a minute between restarts"
done
log "ok: the shell, the auto-lock, the app switcher and the clipboard history never give up, and back off to a minute"

# A lock that cannot be made must keep the machine awake: the guard is a block lock on sleep, and the locker releases it at READY.
grep -qF -- '--what=sleep --mode=block' "$units/vekrona-lock-guard.service" || die "vekrona-lock-guard.service must hold a block lock on sleep"
! grep -q '^\[Install\]' "$units/vekrona-lock-guard.service" || die "the guard must never start by itself: it is held only while the screen is unlocked"
grep -qx 'ExecStartPost=/usr/bin/systemctl --user stop vekrona-lock-guard.service' "$units/vekrona-lock.service" \
  || die "a locker that systemd restarted on its own must release the suspend block when it is ready"
log "ok: the suspend block is held by the guard and released by the locker"

# The lid and the sleep key go through vekrona-suspend (lock, then suspend), so logind must leave them to Sway while the session runs.
grep -qF -- '--what=handle-lid-switch:handle-suspend-key --mode=block' "$units/vekrona-lid.service" || die "vekrona-lid.service must take the lid switch and the sleep key from logind"
grep -qx 'bindswitch --locked lid:on exec vekrona-suspend --lid' "$ROOT/config/sway/config" || die "sway must run vekrona-suspend --lid when the lid closes"
grep -qx 'bindsym --no-repeat --locked XF86Sleep exec vekrona-suspend now' "$ROOT/config/sway/config" || die "sway must run vekrona-suspend on the sleep key"
log "ok: a closed lid and the sleep key lock before they suspend"

# The unit runs outside every login session, where polkit refuses these two inhibitors ("Access denied") unless a rule allows them.
for action in inhibit-handle-lid-switch inhibit-handle-suspend-key; do
  grep -qF "org.freedesktop.login1.$action" "$ROOT/etc/polkit-1/rules.d/50-vekrona-lid.rules" \
    || die "no polkit rule lets the user manager hold $action, which vekrona-lid.service needs"
done
log "ok: polkit lets the lid service hold the inhibitors it asks for"

# Under linger a timer in timers.target polls while nobody is logged in.
for timer in "$units"/*.timer; do
  name="$(basename "$timer")"
  grep -qx 'WantedBy=sway-session.target' "$timer" || die "$name must start with the sway session"
  grep -qx 'PartOf=sway-session.target' "$timer" || die "$name must stop with the sway session"
  ! grep -q 'timers.target' "$timer" || die "$name is wanted by timers.target, so it polls while logged out"
  grep -qE '^AccuracySec=' "$timer" || die "$name needs an AccuracySec, so its wake-up can join others"
done
log "ok: timers belong to the session and coalesce their wake-ups"

# An idle laptop wakes for these once per period.
for timer in vekrona-weather vekrona-calendar; do
  grep -qx 'OnUnitActiveSec=1h' "$units/$timer.timer" || die "$timer.timer must poll hourly: $(grep OnUnitActiveSec "$units/$timer.timer")"
done
log "ok: the weather and calendar polls are hourly"

# A lock that fails before suspend must end the session, so swayidle must call the fail-closed mode.
grep -qF "before-sleep 'vekrona-lock --before-sleep'" "$units/vekrona-idle.service" || die "before-sleep must run vekrona-lock --before-sleep"
log "ok: swayidle locks before sleep in the fail-closed mode"
# A bare vekrona-lock is refused, so the idle timeout and logind's lock request must name the verb.
grep -qF "timeout 300 'vekrona-lock start'" "$units/vekrona-idle.service" || die "the idle timeout must run vekrona-lock start"
grep -qF " lock 'vekrona-lock start'" "$units/vekrona-idle.service" || die "logind's lock request must run vekrona-lock start"
log "ok: swayidle names the verb of vekrona-lock"
