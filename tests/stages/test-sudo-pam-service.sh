#!/usr/bin/env bash
# sudo gets its own PAM service so that pam_systemd registers no logind session for it (they pile up in state "closing",
# systemd issue 43745), while pam_limits and pam_keyinit keep running. The earlier global "Defaults !pam_session" is gone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

PAM="$ROOT/etc/pam.d/vekrona-sudo"
SUDOERS="$ROOT/etc/sudoers.d/50-vekrona-sudo-pam-service"

[[ ! -e "$ROOT/etc/sudoers.d/50-vekrona-no-pam-session" ]] || die "the global '!pam_session' drop-in is back"
! grep -rq 'pam_session' "$ROOT/etc/sudoers.d" || die "a sudoers drop-in switches the PAM session off again"
[[ "$(grep -v '^#' "$SUDOERS" | sed '/^$/d')" == "Defaults pam_service=vekrona-sudo" ]] || die "the drop-in must only select the PAM service: $(cat "$SUDOERS")"
log "ok: sudoers selects the vekrona-sudo PAM service and does not turn the session off"

# The stock service's lines, in order, plus the class line before the include that holds pam_systemd.
mapfile -t lines < <(grep -v '^#' "$PAM" | sed 's/  */ /g')
expected=(
  "auth include system-auth"
  "account include system-auth"
  "password include system-auth"
  "session optional pam_keyinit.so revoke"
  "session required pam_limits.so"
  "session required pam_env.so conffile=/dev/null envfile=/etc/vekrona/sudo-session.env"
  "session include system-auth"
)
[[ "$(printf '%s\n' "${lines[@]}")" == "$(printf '%s\n' "${expected[@]}")" ]] || die "vekrona-sudo is not the stock sudo service plus the class line: ${lines[*]}"
[[ "$(<"$ROOT/etc/vekrona/sudo-session.env")" == "XDG_SESSION_CLASS=none" ]] || die "the PAM environment must make pam_systemd skip the session"
log "ok: vekrona-sudo keeps pam_keyinit, pam_limits and the system-auth session stack, and sets XDG_SESSION_CLASS=none before pam_systemd runs"

# Live check, on a machine that has had stage 40: sudo opens no logind session any more.
if [[ -e /etc/pam.d/vekrona-sudo ]]; then
  before="$(loginctl list-sessions --no-legend | wc -l)"
  for _ in 1 2 3 4 5; do sudo -n true || die "sudo -n true failed: the service vekrona-sudo must authenticate like the stock one"; done
  [[ "$(loginctl list-sessions --no-legend | wc -l)" -eq "$before" ]] || die "sudo registered a logind session"
  log "ok: five sudo calls left the logind sessions as they were"
fi
