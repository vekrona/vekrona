#!/usr/bin/env bash
# The calculator hands every keystroke to qalc, whose export(), load(), plot() and command() write and read files and run
# programs. Typing them must reach no file, and a calculation must still be answered.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
# qalc runs in the shell's working directory (the home folder), so a bare name lands there; the quoted path lands in /tmp.
BARE_FILE='$HOME/vekrona-e2e-calc-bare.csv'
QUOTED_FILE=/tmp/vekrona-e2e-calc-quoted.csv

refused() { vekrona-dev see text 'Couldn.t evaluate'; }
answered() { vekrona-dev see text '\b230\b'; }
export -f refused answered
PANEL_HEX="$(vekrona_token_get color surface-1 dark)"
export PANEL_HEX

cleanup() { vekrona-dev run bash -c "rm -f $BARE_FILE $QUOTED_FILE"; }
trap cleanup EXIT
cleanup

vekrona-dev session
vekrona-dev move 600 500
clear_notifications

vekrona-dev key super-spc
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- panel_shown
vekrona-dev type '/calc '
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.mode == "calc"'

# One row appears whether qalc ran (its answer) or the shell refused (the error row), and qalc writes a file before it answers.
vekrona-dev type 'export([1;2], vekrona-e2e-calc-bare.csv)'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.rows == 1' || { launcher_state; die "the calculator must show one row for an export call"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- refused || die "the calculator must refuse a call of export() instead of evaluating it"
vekrona-dev run bash -c "[[ ! -e $BARE_FILE ]]" || die "typing export() in the calculator wrote $BARE_FILE"
log "ok: typing an export() call into the calculator writes no file and says it was refused"

vekrona-dev key ctrl-a
vekrona-dev key backspace
vekrona-dev type "export([1;2], \"$QUOTED_FILE\")"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- launcher_is '.rows == 1' || { launcher_state; die "the calculator must show one row for a quoted export call"; }
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- refused || die "the calculator must refuse text with quotes"
vekrona-dev run bash -c "[[ ! -e $QUOTED_FILE ]]" || die "typing a quoted export() in the calculator wrote $QUOTED_FILE"
log "ok: text with quotes never reaches qalc"

vekrona-dev key ctrl-a
vekrona-dev key backspace
vekrona-dev type '12.5% of 1840'
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- answered || die "the calculator must still answer 12.5% of 1840"
log "ok: a plain calculation is still answered"
close_launcher
