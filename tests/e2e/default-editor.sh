#!/usr/bin/env bash
# rune is the default editor: the default handler of Markdown and plain text, $EDITOR and $VISUAL of a fresh login, and what git
# commit opens, where a message typed with real keys, saved and quit with rune's own keys becomes the commit.
# shellcheck disable=SC2016 # $variables in the bash -c bodies expand in the guest
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

STEP_TIMEOUT_SEC=60
TERMINAL_APP_ID=com.mitchellh.ghostty
WORK=/tmp/vekrona-e2e-default-editor
NOTE="$WORK/note.md"
NOTE_TEXT="rune opened this note"
REPO="$WORK/repo"
COMMIT_STATUS="$WORK/commit-status"
SESSION_ENV="$WORK/session-env"
COMMIT_MESSAGE="Written in rune with real keys"
EDITOR_DESKTOP=vekrona-rune.desktop

rune_on_note() { vekrona-dev run pgrep -fx "rune $NOTE" >/dev/null; }
rune_running() { vekrona-dev run pgrep -x rune >/dev/null; }
rune_gone() { absent rune_running; }
# rune's footer lists its keys; its text is drawn too small and too dark for OCR to be a reliable witness.
rune_footer_shown() { vekrona-dev see text 'rename'; }
rune_on_commit_message() { vekrona-dev run pgrep -fx "/usr/bin/rune $REPO/.git/COMMIT_EDITMSG" >/dev/null; }
message_saved() { vekrona-dev sh grep -qF "$COMMIT_MESSAGE" "$REPO/.git/COMMIT_EDITMSG"; }
session_env_written() { vekrona-dev sh test -s "$SESSION_ENV"; }
commit_finished() { vekrona-dev sh test -s "$COMMIT_STATUS"; }
export NOTE NOTE_TEXT REPO COMMIT_STATUS COMMIT_MESSAGE SESSION_ENV
export -f rune_on_note rune_running rune_gone rune_footer_shown rune_on_commit_message message_saved session_env_written commit_finished

cleanup() {
  kill_guest -x rune
  vekrona-dev sh rm -rf "$WORK"
}
trap 'run_cleanups cleanup' EXIT

for mime in text/markdown text/x-markdown text/plain; do
  handler="$(vekrona-dev sh xdg-mime query default "$mime")"
  [[ "$handler" == "$EDITOR_DESKTOP" ]] || die "the default handler of $mime must be $EDITOR_DESKTOP, but it is '$handler'"
done
log "ok: $EDITOR_DESKTOP is the default handler of Markdown and plain text"

vekrona-dev session
logout_sway
vekrona-dev session
vekrona-dev sh bash -c 'rm -rf "$1" && mkdir -p "$1"' _ "$WORK"
vekrona-dev sh swaymsg exec "printenv EDITOR VISUAL >$SESSION_ENV" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- session_env_written
[[ "$(vekrona-dev sh cat "$SESSION_ENV")" == $'rune\nrune' ]] || die "a program started by a fresh login must see EDITOR=rune and VISUAL=rune, but printenv says: $(vekrona-dev sh cat "$SESSION_ENV")"
log "ok: a fresh login sets EDITOR and VISUAL to rune"

vekrona-dev sh bash -c 'printf "%s\n" "$1" >"$2"' _ "$NOTE_TEXT" "$NOTE"
vekrona-dev spawn "$WORK/gio-open.log" -- gio open "$NOTE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- rune_on_note || die "gio open did not start rune on $NOTE"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_open "$TERMINAL_APP_ID" || die "rune has no terminal window"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- rune_footer_shown || die "rune is not drawn on screen"
log "ok: opening a Markdown file shows it in rune, in a terminal window"
kill_guest -x rune
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- rune_gone
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- window_closed "$TERMINAL_APP_ID"

vekrona-dev sh bash -c '
git init -q "$1"
git -C "$1" config user.name e2e
git -C "$1" config user.email e2e@example.invalid
printf "%s\n" "#!/usr/bin/env bash" "cd \"$1\"" "git commit --allow-empty" "echo \$? >\"$3\"" >"$2/commit.sh"
chmod +x "$2/commit.sh"' _ "$REPO" "$WORK" "$COMMIT_STATUS"
vekrona-dev sh swaymsg exec "ghostty -e $WORK/commit.sh" >/dev/null
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- rune_on_commit_message || die "git commit did not start rune on its message file"
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- rune_footer_shown || die "rune is not drawn on screen"
vekrona-dev type "$COMMIT_MESSAGE"
vekrona-dev key ctrl-s
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- message_saved || die "ctrl-s did not save the message"
# a first ctrl-c only asks to press it again
vekrona-dev key ctrl-c ctrl-c
vekrona-dev until --timeout "$STEP_TIMEOUT_SEC" -- commit_finished || die "ctrl-c did not end the editor, so git commit never returned"
[[ "$(vekrona-dev sh cat "$COMMIT_STATUS")" == 0 ]] || die "git commit failed with status $(vekrona-dev sh cat "$COMMIT_STATUS")"
subject="$(vekrona-dev sh git -C "$REPO" log -1 --format=%s)"
[[ "$subject" == "$COMMIT_MESSAGE" ]] || die "the commit's message must be '$COMMIT_MESSAGE', but it is '$subject'"
log "ok: git commit takes its message from rune"
