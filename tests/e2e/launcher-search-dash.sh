#!/usr/bin/env bash
# A search term that looks like an option is a term: it must reach the bookmark and history lookup as one, which then finds
# nothing, not fail on a usage error that shows up as an error row.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# How long the lookup is given to fail, which it must not. It runs in well under a second.
QUIET_SEC=10
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export PANEL_HEX

lookup_failed() { launcher_is '.mode == "search" and .rows == 2'; }
export -f lookup_failed

vekrona-dev session
vekrona-dev move 600 500
clear_notifications
errors_before="$(shell_errors)"

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type '/search '
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.mode == "search"'
vekrona-dev type -- '-v'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.query == "-v" and .rows >= 1' || { launcher_state; die "/search must list its search row for -v"; }
! vekrona-dev until --timeout "$QUIET_SEC" -- lookup_failed || { launcher_state; die "the lookup of the term -v failed and listed an error row"; }
[[ "$(shell_errors)" == "$errors_before" ]] || die "the lookup of the term -v logged a shell error"
log "ok: a search term that starts with a dash is looked up as a term"
close_launcher
