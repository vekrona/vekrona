#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
tool="$ROOT/bin/vekrona-screenshot"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export SCRATCH="$scratch" HOME="$scratch/home"
logs="$scratch/logs"
stubs="$scratch/stubs"
shots="$HOME/Pictures/Screenshots"
mkdir -p "$stubs" "$logs" "$HOME"

# Tiled window, floating window, hidden-workspace window, and a pid-less container.
cat > "$scratch/tree.json" <<'JSON'
{"type":"root","rect":{"x":0,"y":0,"width":3840,"height":1080},"nodes":[
 {"type":"output","name":"eDP-1","rect":{"x":0,"y":0,"width":1920,"height":1080},"nodes":[
  {"type":"workspace","visible":true,"rect":{"x":0,"y":0,"width":1920,"height":1080},
   "nodes":[{"type":"con","pid":11,"visible":true,"rect":{"x":0,"y":0,"width":960,"height":1080},"nodes":[],"floating_nodes":[]}],
   "floating_nodes":[{"type":"floating_con","pid":12,"visible":true,"rect":{"x":100,"y":200,"width":400,"height":300},"nodes":[]}]},
  {"type":"workspace","visible":false,"rect":{"x":0,"y":0,"width":1920,"height":1080},
   "nodes":[{"type":"con","pid":13,"visible":false,"rect":{"x":5,"y":6,"width":70,"height":80},"nodes":[],"floating_nodes":[]}],
   "floating_nodes":[]}]}]}
JSON
echo '[{"name":"eDP-1","focused":false},{"name":"DP-2","focused":true}]' > "$scratch/outputs.json"

stub() { printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$2" > "$stubs/$1"; chmod +x "$stubs/$1"; }

stub grim 'echo "$*" >> "$SCRATCH/logs/grim"
if [[ "${*: -1}" == - ]]; then printf PNGBYTES; else printf PNGBYTES > "${*: -1}"; fi
[[ "${GRIM_FAIL:-}" != 1 ]] || exit 1'
stub slurp 'echo "$*" >> "$SCRATCH/logs/slurp"
cat > "$SCRATCH/logs/slurp.stdin"
if [[ -n "${SLURP_OUT:-}" ]]; then echo "$SLURP_OUT"; else echo "${SLURP_ERR:-selection cancelled}" >&2; exit 1; fi'
stub swaymsg 'case "$2" in get_tree) cat "$SCRATCH/tree.json";; get_outputs) cat "$SCRATCH/outputs.json";; *) exit 1;; esac'
stub wl-copy 'cat > "$SCRATCH/logs/clip"
[[ "${WL_COPY_FAIL:-}" != 1 ]] || exit 1'
stub notify-send 'echo "$*" >> "$SCRATCH/logs/notify"
[[ "${NOTIFY_FAIL:-}" != 1 ]] || exit 1
printf "%s" "${NOTIFY_ACTION:-}"'
stub swappy 'echo "$*" >> "$SCRATCH/logs/swappy"'
stub gio 'echo "$*" >> "$SCRATCH/logs/gio"
[[ "${GIO_FAIL:-}" != 1 ]] || exit 1'

run_shot() {
  rm -rf "$logs" "$HOME/Pictures"
  mkdir -p "$logs"
  rc=0
  PATH="$stubs:$PATH" "$tool" "$@" >/dev/null 2>"$scratch/stderr" || rc=$?
}

saved_file() { find "$shots" -name '*.png' 2>/dev/null | head -n 1; }
no_files() { [[ -z "$(saved_file)" ]]; }
logged() { [[ -e "$logs/$1" ]]; }
expect_rc() { [[ "$rc" == "$1" ]] || die "$2: expected exit $1, got $rc: $(cat "$scratch/stderr")"; }

run_shot screen
expect_rc 0 "screen"
file="$(saved_file)"
[[ -n "$file" ]] || die "screen: no file saved"
grep -qx -- "-o DP-2 $file" "$logs/grim" || die "screen: grim must get the focused output: $(cat "$logs/grim")"
cmp -s "$file" "$logs/clip" || die "screen: clipboard must hold the saved bytes"
log "ok: screen saves the focused output and copies the same bytes"

SLURP_OUT="100,200 400x300" run_shot area
expect_rc 0 "area"
[[ "$(cat "$logs/slurp.stdin")" == $'0,0 960x1080\n100,200 400x300' ]] \
  || die "area: slurp must be offered exactly the visible windows, got: $(cat "$logs/slurp.stdin")"
grep -q -- "-g 100,200 400x300 " "$logs/grim" || die "area: grim must get slurp's geometry: $(cat "$logs/grim")"
log "ok: area offers visible windows as click targets"

SLURP_OUT="0,0 960x1080" run_shot window
expect_rc 0 "window"
grep -qx -- "-r" "$logs/slurp" || die "window: slurp must get -r: $(cat "$logs/slurp")"
SLURP_OUT="0,0 960x1080" run_shot area
if grep -q -- "-r" "$logs/slurp"; then die "area: slurp must allow free drags"; fi
log "ok: window restricts selection to windows"

run_shot --clipboard screen
expect_rc 0 "--clipboard"
no_files || die "--clipboard: no file may be saved"
[[ "$(cat "$logs/clip")" == PNGBYTES ]] || die "--clipboard: image must reach the clipboard"
if grep -q -- "-A" "$logs/notify"; then die "--clipboard: notification must have no Edit action"; fi
log "ok: --clipboard saves no file"

run_shot area
expect_rc 0 "Esc"
no_files || die "Esc: no file may be saved"
logged clip && die "Esc: nothing may reach the clipboard"
logged notify && die "Esc: no notification expected"
[[ ! -s "$scratch/stderr" ]] || die "Esc: must be silent: $(cat "$scratch/stderr")"
log "ok: Esc cancels quietly"

GRIM_FAIL=1 run_shot screen
expect_rc 1 "grim failure"
no_files || die "grim failure: a partial file must not remain"
grep -q -- "-u critical" "$logs/notify" || die "grim failure: critical notification expected"
log "ok: grim failure leaves no file and notifies critical"

NOTIFY_ACTION=edit run_shot screen
expect_rc 0 "Edit"
[[ "$(cat "$logs/swappy")" == "-f $(saved_file)" ]] || die "Edit: swappy must open the saved file: $(cat "$logs/swappy")"
log "ok: Edit action opens swappy on the saved file"

run_shot lizard
expect_rc 2 "lizard"
run_shot ""
expect_rc 2 "empty mode"
run_shot screen extra
expect_rc 2 "extra argument"
logged grim && die "bad usage: nothing may be captured"
run_shot --clipboard lizard
expect_rc 2 "--clipboard lizard"
log "ok: unknown mode exits 2"

SLURP_ERR="compositor doesn't support wlr-layer-shell" run_shot area
expect_rc 1 "slurp error"
grep -q "wlr-layer-shell" "$scratch/stderr" || die "slurp error: must be reported on stderr"
grep -q -- "-u critical" "$logs/notify" || die "slurp error: critical notification expected"
logged grim && die "slurp error: nothing may be captured"
log "ok: a slurp error other than cancel is reported"

WL_COPY_FAIL=1 run_shot screen
expect_rc 1 "clipboard failure"
[[ -n "$(saved_file)" ]] || die "clipboard failure: the saved file must be kept"
grep -q -- "-u critical" "$logs/notify" || die "clipboard failure: critical notification expected"
log "ok: a clipboard failure keeps the saved file"

NOTIFY_FAIL=1 run_shot screen
[[ "$rc" != 0 ]] || die "notification failure: must exit non-zero"
[[ -n "$(saved_file)" ]] || die "notification failure: the saved file must be kept"
log "ok: a notification failure keeps the saved file"

NOTIFY_ACTION="" run_shot screen
expect_rc 0 "dismissed"
logged swappy && die "dismissed: no editor expected"
logged gio && die "dismissed: no trash action expected"
log "ok: a dismissed notification opens no editor"

NOTIFY_ACTION=delete run_shot screen
expect_rc 0 "Delete"
file="$(saved_file)"
[[ -n "$file" ]] || die "Delete: file must be saved"
[[ "$(cat "$logs/gio")" == "trash $file" ]] || die "Delete: gio must be called with trash: $(cat "$logs/gio")"
logged swappy && die "Delete: no editor expected"
log "ok: Delete action moves the saved file to the trash"

GIO_FAIL=1 NOTIFY_ACTION=delete run_shot screen
expect_rc 1 "trash failure"
log "ok: a trash failure is reported"
