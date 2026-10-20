#!/usr/bin/env bash
# An application whose .desktop file has a Path starts in that folder.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
ENTRY=VekronaPathProbe
START_DIR=/usr/share
APPLICATIONS_DIR='$HOME/.local/share/applications'
MARKER=/tmp/vekrona-e2e-apps-path
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export PANEL_HEX

entry_listed() { vekrona-dev see text "$ENTRY"; }
marker_written() { vekrona-dev sh test -s "$MARKER"; }
export -f entry_listed marker_written
export ENTRY MARKER

cleanup() { vekrona-dev sh bash -c "rm -f $APPLICATIONS_DIR/$ENTRY.desktop $MARKER"; }
trap cleanup EXIT
cleanup


vekrona-dev session
vekrona-dev move 600 500
clear_notifications
vekrona-dev sh bash -c "mkdir -p $APPLICATIONS_DIR && printf '[Desktop Entry]\nType=Application\nName=$ENTRY\nPath=$START_DIR\nExec=sh -c \"pwd > $MARKER\"\n' >$APPLICATIONS_DIR/$ENTRY.desktop"
vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type "$ENTRY"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- entry_listed
vekrona-dev key ret
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- marker_written || die "the application did not run"
[[ "$(vekrona-dev sh cat "$MARKER")" == "$START_DIR" ]] || die "the application must start in the Path of its .desktop file, $START_DIR, but started in $(vekrona-dev sh cat "$MARKER")"
log "ok: an application starts in the Path of its .desktop file"
