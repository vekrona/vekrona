#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
INSTALL_TIMEOUT_SEC=600
GUEST_PASSWORD=vekrona
LOCK_CHORD=super-ctrl-alt-esc

shell_property() { vekrona-dev sh systemctl --user show vekrona-shell -p "$1" --value; }
shell_active() { [[ "$(shell_property ActiveState)" == active ]]; }
lock_active() { vekrona-dev sh systemctl --user is-active --quiet vekrona-lock; }
lock_inactive() { ! lock_active; }
locked_hint() { [[ "$(vekrona-dev sh loginctl show-session auto -p LockedHint --value)" == yes ]]; }
export -f shell_property shell_active lock_active lock_inactive locked_hint

vekrona-dev session
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_active
invocation_before="$(shell_property InvocationID)"

vekrona-dev sh bash -c 'rm -f "$HOME/.local/bin/vekrona-firefox" "$HOME/.config/quickshell/vekrona-lock"'
vekrona-dev sh bash -c 'test ! -e "$HOME/.local/bin/vekrona-firefox" && test ! -e "$HOME/.config/quickshell/vekrona-lock"' \
  || die "the shell's files were not removed, so the scenario would not reproduce a reinstall over missing files"

install_log="$(mktemp)"
trap 'rm -f "$install_log"' EXIT
vekrona-dev sh timeout "$INSTALL_TIMEOUT_SEC" bash -c 'cd "$HOME/.local/share/vekrona" && ./install.sh 50-user' >"$install_log" 2>&1 \
  || die "stage 50 failed inside the live session:
$(<"$install_log")"
log "ok: stage 50 ran inside the live session"

invocation_after="$(shell_property InvocationID)"
[[ "$invocation_after" != "$invocation_before" ]] || die "install did not restart vekrona-shell, so the running shell never loaded the restored files"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_active
[[ "$(shell_property NRestarts)" == 0 ]] || die "vekrona-shell restarted by itself after install: NRestarts=$(shell_property NRestarts)"
log "ok: the shell is active after install and has not restarted by itself"

vekrona-dev key "$LOCK_CHORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_active
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- locked_hint
log "ok: the lock key binding locks the screen after install"

vekrona-dev type --enter "$GUEST_PASSWORD"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- lock_inactive

shell_log="$(vekrona-dev sh journalctl --user --no-pager -o cat "_SYSTEMD_INVOCATION_ID=$invocation_after")"
! grep -F 'vekrona-firefox' <<<"$shell_log" || die "the restarted shell ran vekrona-firefox before install had linked it:
$(grep -F 'vekrona-firefox' <<<"$shell_log")"
log "ok: the restarted shell found every file it executes"
