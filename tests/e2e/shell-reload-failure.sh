#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
source "$ROOT/tests/e2e/lib/bar-dot.sh"

STEP_TIMEOUT_SEC=60
# Where the pointer rests: over no widget.
PARK_X=600
PARK_Y=500
BAR_QML='$HOME/.local/share/vekrona/config/vekrona-shell/Bar.qml'
BAR_QML_ORIGINAL=/tmp/shell-reload-failure-Bar.qml
BROKEN_TYPE=NoSuchPill
DANGER_HEX="$(vekrona_token_get color danger dark)"
BAR_HEIGHT_PX=$(($(vekrona_token_get size size-bar) - $(vekrona_token_get border border-hair)))
ICON_S_PX="$(vekrona_token_get size size-icon-s)"

broken_records() { vekrona-dev run bash -c "vekrona-error list --all | grep -cF '$BROKEN_TYPE is not a type' || [[ \$? -eq 1 ]]"; }
broken_recorded() { [[ "$(broken_records)" -ge 1 ]]; }
# How many times the shell has loaded a configuration, which a reload that fails does not count. The shell watches its files
# only once it has loaded, and answers on its IPC before that, so an edit right after a restart goes unseen.
loads() { vekrona-dev run bash -c "journalctl --user -u vekrona-shell.service -o cat | grep -cF 'Configuration Loaded' || [[ \$? -eq 1 ]]"; }
loaded_more_than() { (($(loads) > $1)); }
export -f broken_records broken_recorded loads loaded_more_than
export ROOT DANGER_HEX BAR_HEIGHT_PX BROKEN_TYPE

# Both write the file in place, since the shell does not notice a file that is replaced by a rename, as sed -i and git do.
restore_bar() { vekrona-dev run bash -c "[[ ! -e $BAR_QML_ORIGINAL ]] || { cat $BAR_QML_ORIGINAL >$BAR_QML && rm $BAR_QML_ORIGINAL; }"; }
break_bar() { vekrona-dev run bash -c "cp $BAR_QML $BAR_QML_ORIGINAL && sed 's/^        Tray {}\$/        $BROKEN_TYPE {}\n&/' $BAR_QML_ORIGINAL >$BAR_QML"; }
remove_broken_records() {
  local id
  for id in $(vekrona-dev run bash -c "vekrona-error list --all | grep -F '$BROKEN_TYPE is not a type' | awk '{print \$1}'"); do
    vekrona-dev run vekrona-error rm "$id"
  done
}
remove_dot_files() { rm -f "$DOT_FILE" "$DOT_STATES"; }

DOT_FILE="$(mktemp)"
export DOT_FILE
trap 'run_cleanups restore_bar remove_broken_records unread_restore remove_dot_files' EXIT

vekrona-dev session
vekrona-dev move "$PARK_X" "$PARK_Y"
unread_stash
vekrona-dev run vekrona-error ack --all
remove_broken_records
loads_before="$(loads)"
restart_shell
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- loaded_more_than "$loads_before" || die "the restarted shell must load its configuration"
vekrona-dev sh systemctl --user start vekrona-errors.service
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- no_dot || die "the robot must show no dot before the shell reload breaks"

# The installed config is a symlink to the guest checkout, and quickshell reloads when a file in it changes.
break_bar
vekrona-dev run bash -c "grep -qF '$BROKEN_TYPE {}' $BAR_QML" || die "the scenario could not break Bar.qml"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- broken_recorded || die "a shell reload that fails twice must record an error naming '$BROKEN_TYPE is not a type'"
[[ "$(broken_records)" == 1 ]] || die "a failed reload must make one record, but it made $(broken_records)"
log "ok: a shell reload that fails is recorded as one error that names the cause"

vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- robot_dotted || { cat "$DOT_FILE"; die "the recorded reload failure must raise the robot's dot"; }
dot_left="$(sed -n '1s/^dot: x \([0-9]*\)\..*/\1/p' "$DOT_FILE")"
robot_x=$((dot_left - ICON_S_PX / 2))
robot_y=$((BAR_HEIGHT_PX / 2))
log "ok: the recorded reload failure raises the robot's dot"

vekrona-dev click "$robot_x" "$robot_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.open and .mode == "agent"' || { launcher_state; die "the shell must keep its previous version: a left click on the robot must open the error list"; }
vekrona-dev click "$robot_x" "$robot_y"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_closed || die "a second left click on the robot must close the error list"
log "ok: after a failed reload the shell runs its previous version, and the robot opens the error list"

# A shell whose reload failed no longer watches its files, so a restart is how it picks up the fixed file.
restore_bar
loads_before="$(loads)"
restart_shell
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- loaded_more_than "$loads_before" || die "a shell restarted on the restored Bar.qml must load its configuration"
log "ok: with the file fixed, the restarted shell loads it"
