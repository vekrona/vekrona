#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=30
SWAY_CONFIG='$HOME/.config/sway/config'
SWAY_CONFIG_ORIGINAL=/tmp/sway-config-follows-edits-original
EDIT_ID="$$-$(date +%s)"
IN_PLACE_MARKER="# e2e sway follows an in-place edit $EDIT_ID"
RENAME_MARKER="# e2e sway follows a rename over its config $EDIT_ID"
WRITE_BACK_MARKER="# e2e sway follows the write after a truncate $EDIT_ID"
INVALID_LINE="e2e_sway_rejects_this_directive_$EDIT_ID"

# Sway answers get_config with the config it has loaded, not the file on disk.
sway_has() { vekrona-dev sh bash -c "swaymsg -t get_config | jq -er .config | grep -qxF '$1'"; }
sway_lacks() { ! sway_has "$1"; }
# The shell logs a change it does not act on, and a config that sway rejects as an error.
shell_logged() { vekrona-dev sh bash -c "journalctl --user --no-pager -o cat --after-cursor '$JOURNAL_CURSOR' -t vekrona-shell | grep -qF '$1'"; }
rejection_recorded() { vekrona-dev sh bash -c "vekrona-error list --all | grep -qF 'sway rejects it'"; }
export -f sway_has sway_lacks shell_logged rejection_recorded

# Writes in place, so the restore is itself a plain edit; the shell reloads Sway for it as it does for any edit.
restore_config() { vekrona-dev run bash -c "[[ ! -e $SWAY_CONFIG_ORIGINAL ]] || { cat $SWAY_CONFIG_ORIGINAL >\"\$(readlink -f $SWAY_CONFIG)\" && rm $SWAY_CONFIG_ORIGINAL; }"; }
# The installed config is a symlink into the guest checkout; git and editors replace the file there by a rename.
edit_in_place() { vekrona-dev run bash -c "[[ -e $SWAY_CONFIG_ORIGINAL ]] || cp $SWAY_CONFIG $SWAY_CONFIG_ORIGINAL; printf '%s\n' '$1' >>$SWAY_CONFIG"; }
replace_by_rename() { vekrona-dev run bash -c "target=\"\$(readlink -f $SWAY_CONFIG)\" && cp \"\$target\" \"\$target.new\" && printf '%s\n' '$1' >>\"\$target.new\" && mv \"\$target.new\" \"\$target\""; }

# The rejection this scenario provokes is recorded in the error store, and goes again so that it does not stay unread for the next one.
forget_rejection() {
  vekrona-dev run bash -c 'vekrona-error list --all | grep -F "sway rejects it" | while read -r id _; do vekrona-error rm "$id"; done'
  vekrona-dev run vekrona-error refresh-unread
}

trap 'run_cleanups restore_config forget_rejection' EXIT

vekrona-dev session
vekrona-dev until --timeout 60 -- shell_ready || die "the session's shell must answer before the scenario edits the sway config"

edit_in_place "$IN_PLACE_MARKER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sway_has "$IN_PLACE_MARKER" || die "sway must follow an in-place edit of its config"
log "ok: sway follows an in-place edit of its config"

replace_by_rename "$RENAME_MARKER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sway_has "$RENAME_MARKER" || die "sway must follow a rename over its config"
log "ok: sway follows a rename over its config"

# For a change that the shell does not pass on to sway, nothing in sway tells that the shell has handled it. The shell's log line
# does, and a reload could only have followed that handling, so no wait stands in for it. Only this run's lines count.
JOURNAL_CURSOR="$(vekrona-dev sh journalctl --user -n 0 --show-cursor | sed -n 's/^-- cursor: //p')"
[[ -n "$JOURNAL_CURSOR" ]] || die "cannot read the user journal's cursor"
export JOURNAL_CURSOR

# An editor that writes in place truncates first: sway must not reload the empty file, which would drop every binding.
truncate_in_place() { vekrona-dev run bash -c "truncate -s 0 \"\$(readlink -f $SWAY_CONFIG)\""; }
# The pristine config and a marker, written in place over what is there.
write_back() { vekrona-dev run bash -c "{ cat $SWAY_CONFIG_ORIGINAL; printf '%s\n' '$1'; } >\"\$(readlink -f $SWAY_CONFIG)\""; }
truncate_in_place
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_logged 'is empty, waiting for the write to finish' || die "the shell must notice that the config was emptied"
sway_has "$RENAME_MARKER" || die "sway must keep the config it runs while the config file is empty"
write_back "$WRITE_BACK_MARKER"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sway_has "$WRITE_BACK_MARKER" || die "sway must follow the write that completes an emptied config"
log "ok: an emptied config is not reloaded, the completed write is"

# The reload happens only for a config that sway accepts: the log line is the shell's answer to the edit, and a reload would
# only follow a successful validation, so once the line is there sway still runs the previous config.
edit_in_place "$INVALID_LINE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- shell_logged 'sway rejects it' || die "the shell must log a config that sway rejects"
sway_has "$WRITE_BACK_MARKER" || die "sway must keep the config it runs when the edit is rejected"
sway_lacks "$INVALID_LINE" || die "sway must not load a config that it rejects"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- rejection_recorded || die "the rejected config must be recorded as an error"
log "ok: a config that sway rejects is logged, recorded and not reloaded"

restore_config
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- sway_lacks "$WRITE_BACK_MARKER" || die "sway must follow the fixed config again after a rejected one"
log "ok: sway reloads again once the config is valid"
