#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
tool="$ROOT/bin/vekrona-suspend"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch"
logs="$scratch/logs"
stubs="$scratch/stubs"
mkdir -p "$stubs" "$logs"

write_fake "$stubs/vekrona-lock" <<'F'
#!/usr/bin/env bash
echo lock >>"$SCRATCH/logs/calls"
[[ -z "${LOCK_FAILS:-}" ]] || exit 1
F
write_fake "$stubs/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SCRATCH/logs/calls"
[[ -z "${SUSPEND_FAILS:-}" ]] || exit 1
F
write_fake "$stubs/swaymsg" <<'F'
#!/usr/bin/env bash
[[ -z "${SWAYMSG_FAILS:-}" ]] || exit 1
printf '%s\n' "$OUTPUTS"
F
write_fake "$stubs/reporter" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$SCRATCH/logs/reported"
F
export VEKRONA_ERROR_REPORTER="$stubs/reporter"
one_output='[{"name":"eDP-1","active":true}]'
two_outputs='[{"name":"eDP-1","active":true},{"name":"DP-1","active":false}]'

run_suspend() {
  rm -rf "$logs"
  mkdir -p "$logs"
  rc=0
  PATH="$stubs:$PATH" "$tool" "$@" >/dev/null 2>"$scratch/stderr" || rc=$?
}
expect_rc() { [[ "$rc" == "$1" ]] || die "$2: expected exit $1, got $rc: $(cat "$scratch/stderr")"; }
calls() { cat "$logs/calls" 2>/dev/null || true; }

run_suspend now
expect_rc 0 "a suspend"
[[ "$(calls)" == $'lock\nsystemctl suspend' ]] || die "a suspend must lock first, then suspend: $(calls)"
log "ok: the machine suspends only after the lock"

LOCK_FAILS=1 run_suspend now
expect_rc 1 "a suspend whose lock fails"
[[ "$(calls)" == lock ]] || die "a failed lock must not be followed by a suspend: $(calls)"
log "ok: a failed lock stops the suspend"

SUSPEND_FAILS=1 run_suspend now
expect_rc 1 "a suspend that logind refuses"
grep -q 'systemctl suspend failed' "$logs/reported" || die "a refused suspend must be reported: $(cat "$logs/reported" 2>&1)"
log "ok: a refused suspend is reported"

OUTPUTS="$one_output" run_suspend --lid
expect_rc 0 "a lid closed on the laptop alone"
[[ "$(calls)" == $'lock\nsystemctl suspend' ]] || die "a closed lid on the laptop alone must lock, then suspend: $(calls)"
log "ok: a closed lid suspends a laptop with no external display"

OUTPUTS="$two_outputs" run_suspend --lid
expect_rc 0 "a lid closed with an external display"
[[ -z "$(calls)" ]] || die "a docked laptop must stay awake when the lid closes: $(calls)"
log "ok: a closed lid does nothing while an external display is connected"

SWAYMSG_FAILS=1 OUTPUTS="$one_output" run_suspend --lid
expect_rc 1 "a lid event when sway cannot be asked"
[[ -z "$(calls)" ]] || die "an unknown display setup must neither lock nor suspend: $(calls)"
log "ok: a lid event with sway unreachable fails"

OUTPUTS="not json" run_suspend --lid
expect_rc 1 "a lid event with a garbled output list"
[[ -z "$(calls)" ]] || die "a garbled output list must neither lock nor suspend: $(calls)"
log "ok: a garbled output list fails"

run_suspend --bogus
expect_rc 2 "an unknown option"
[[ -z "$(calls)" ]] || die "an unknown option must neither lock nor suspend: $(calls)"
log "ok: an unknown option is refused"
