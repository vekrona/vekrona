#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/units"

# systemctl stub over one file per unit: $work/units/<unit>.enabled holds the is-enabled answer, <unit>.active exists
# while the unit runs. enable/disable change the answer unless STUCK is set; --now also starts/stops. Every call is logged.
# PROBE_FAIL="<status> <stderr text>" makes is-enabled and is-active fail like an unreachable bus: that status, no state on stdout.
cat > "$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "systemctl $*" >> "$STUB_LOG"
verb="$1"; shift
[[ "${1-}" == --now ]] && { now=1; shift; } || now=
unit="$1"
f="$UNITS/$unit"
if [[ -n "${PROBE_FAIL-}" && "$verb" == is-* ]]; then
  echo "${PROBE_FAIL#* }" >&2
  exit "${PROBE_FAIL%% *}"
fi
case "$verb" in
  is-enabled)
    [[ -e "$f.enabled" ]] || { echo not-found; exit 4; }
    cat "$f.enabled"; [[ "$(cat "$f.enabled")" == enabled ]] || exit 1 ;;
  is-active)  if [[ -e "$f.active" ]]; then echo active; else echo inactive; exit 3; fi ;;
  enable)  [[ -n "${STUCK-}" ]] || echo enabled > "$f.enabled"; [[ -z "$now" ]] || touch "$f.active" ;;
  disable) [[ -n "${STUCK-}" ]] || echo disabled > "$f.enabled"; [[ -z "$now" ]] || rm -f "$f.active" ;;
  start) touch "$f.active" ;;
  stop)  rm -f "$f.active" ;;
  *) exit 2 ;;
esac
FAKE
cat > "$work/bin/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" UNITS="$work/units"

# unit <name> <is-enabled answer> [active]
unit() { echo "$2" > "$UNITS/$1.enabled"; rm -f "$UNITS/$1.active"; [[ -z "${3-}" ]] || touch "$UNITS/$1.active"; : > "$STUB_LOG"; }
mutating_calls() { grep -cE '^systemctl (enable|disable|start|stop) ' "$STUB_LOG" || true; }

unit a disabled
(ensure_system_unit enabled a) 2>/dev/null
[[ "$(<"$UNITS/a.enabled")" == enabled ]] || die "a disabled unit was not enabled"
(ensure_system_unit enabled a) 2>/dev/null
[[ "$(grep -c '^systemctl enable' "$STUB_LOG")" -eq 1 ]] || die "an enabled unit was enabled again"
log "ok: a unit is enabled once and then left alone"

for state in masked static disabled; do
  unit b "$state"
  (ensure_system_unit disabled b) 2>/dev/null || die "a $state unit was not accepted as disabled"
  [[ "$(mutating_calls)" -eq 0 ]] || die "a $state unit was touched to make it disabled"
done
log "ok: masked, static and disabled units already satisfy 'disabled'"

unit c enabled active
(ensure_system_unit --now disabled c) 2>/dev/null
[[ "$(<"$UNITS/c.enabled")" == disabled && ! -e "$UNITS/c.active" ]] || die "--now disabled left the unit enabled or running"
log "ok: --now disabled disables and stops an enabled running unit"

unit d masked active
(ensure_system_unit --now disabled d) 2>/dev/null
[[ ! -e "$UNITS/d.active" ]] || die "--now disabled left a masked but running unit running"
log "ok: --now disabled stops a running unit that is already masked"

unit e disabled
(ensure_system_unit --now enabled e) 2>/dev/null
[[ "$(<"$UNITS/e.enabled")" == enabled && -e "$UNITS/e.active" ]] || die "--now enabled did not enable and start the unit"
log "ok: --now enabled enables and starts a unit"

unit f enabled active
(ensure_system_unit disabled f) 2>/dev/null
[[ -e "$UNITS/f.active" ]] || die "without --now the running state was changed"
log "ok: without --now a running unit keeps running"

unit g enabled
if (STUCK=1 ensure_system_unit disabled g) 2>"$work/err"; then die "a disable that did not take effect was not reported"; fi
grep -q 'unit g not disabled' "$work/err" || die "a failed disable did not say so: $(cat "$work/err")"
if (ensure_system_unit sideways g) 2>"$work/err"; then die "an unknown state was accepted"; fi
log "ok: a state that does not stick and an unknown state are errors"

rm -f "$UNITS/h.enabled"; : > "$STUB_LOG"
(ensure_system_unit enabled h) 2>/dev/null
[[ "$(<"$UNITS/h.enabled")" == enabled ]] || die "a unit systemctl reports as not-found (status 4) was not enabled"
log "ok: a not-found unit reads as not enabled, not as a probe failure"

unit i enabled
if (ensure_system_unit_active i) 2>/dev/null; then :; fi
[[ -e "$UNITS/i.active" ]] || die "an inactive unit (status 3) was not started"
log "ok: an inactive unit (status 3) reads as not active"

for failure in "5 unexpected failure" "1 Failed to connect to bus: No such file or directory"; do
  unit j enabled
  if (PROBE_FAIL="$failure" ensure_system_unit enabled j) 2>"$work/err"; then die "a failing is-enabled probe ($failure) was accepted"; fi
  grep -q "systemctl is-enabled j" "$work/err" && grep -q "${failure#* }" "$work/err" || die "a failing probe ($failure) did not report itself: $(cat "$work/err")"
  [[ "$(mutating_calls)" -eq 0 ]] || die "a failing probe ($failure) was followed by a change"
  if (PROBE_FAIL="$failure" ensure_system_unit_active j) 2>/dev/null; then die "a failing is-active probe ($failure) was accepted"; fi
  [[ "$(mutating_calls)" -eq 0 ]] || die "a failing is-active probe ($failure) was followed by a change"
done
log "ok: an unexpected exit status or a missing state word from systemctl dies instead of reading as 'no'"
