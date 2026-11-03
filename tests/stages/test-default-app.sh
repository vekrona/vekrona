#!/usr/bin/env bash
# ensure_default_app makes a .desktop file the default handler of every MIME type, and dies when it cannot tell or cannot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
defaults="$scratch/defaults"
guesses="$scratch/guesses"
mkdir -p "$stubs" "$defaults" "$guesses"
export DEFAULTS="$defaults" GUESSES="$guesses"

# An xdg-mime over one file per MIME type (the slash becomes a comma). A query answers from the stored default, else from
# the guess file of that type (xdg-mime guesses from the installed .desktop files when nothing is stored). XDG_FAIL=query
# makes every query fail, XDG_FAIL=default makes every set fail, XDG_IGNORE_SET=1 makes a set succeed without storing anything.
cat >"$stubs/xdg-mime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
key() { printf '%s/%s' "$DEFAULTS" "${1//\//,}"; }
case "$1 $2" in
  "query default")
    [[ "${XDG_FAIL:-}" != query ]] || exit 4
    if [[ -f "$(key "$3")" ]]; then cat "$(key "$3")"; elif [[ -f "$GUESSES/${3//\//,}" ]]; then cat "$GUESSES/${3//\//,}"; fi
    ;;
  "default "*)
    [[ "${XDG_FAIL:-}" != default ]] || exit 4
    [[ -n "${XDG_IGNORE_SET:-}" ]] || printf '%s\n' "$2" >"$(key "$3")"
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$stubs/xdg-mime"

ensure() { rc=0; (PATH="$stubs:$PATH" ensure_default_app "$@") >"$scratch/out" 2>&1 || rc=$?; }
handler_of() { PATH="$stubs:$PATH" xdg-mime query default "$1"; }
reset() { rm -f "$defaults"/* "$guesses"/*; }
stored() { [[ "$(cat "$defaults/${1//\//,}" 2>/dev/null)" == "$2" ]]; }

APP=vekrona-rune.desktop
MIMES=(text/markdown text/plain)

reset
ensure "$APP" "${MIMES[@]}"
[[ "$rc" == 0 && "$(handler_of text/markdown)" == "$APP" && "$(handler_of text/plain)" == "$APP" ]] || die "the app did not become the default of every MIME type: rc=$rc: $(cat "$scratch/out")"
log "ok: the app becomes the default handler of every MIME type"

reset
echo "$APP" >"$guesses/text,plain"
ensure "$APP" text/plain
if ! { [[ "$rc" == 0 ]] && stored text/plain "$APP"; }; then die "a type that xdg-mime only guesses to be the app's was not stored as its default: rc=$rc: $(cat "$scratch/out")"; fi
log "ok: a guess that names the app is not taken for its default"

ensure "$APP" text/plain
[[ "$rc" == 0 ]] || die "setting a default twice failed: rc=$rc: $(cat "$scratch/out")"
log "ok: setting a default twice is fine"

reset
echo other.desktop >"$defaults/text,plain"
ensure "$APP" text/plain
[[ "$rc" == 0 && "$(handler_of text/plain)" == "$APP" ]] || die "another app's default was not replaced: rc=$rc: $(cat "$scratch/out")"
log "ok: another app's default is replaced"

reset
XDG_IGNORE_SET=1 ensure "$APP" text/plain
if ! { [[ "$rc" != 0 ]] && grep -q 'default handler not applied: text/plain' "$scratch/out"; }; then die "a set that xdg-mime does not apply must fail: rc=$rc: $(cat "$scratch/out")"; fi
log "ok: a default that xdg-mime does not report afterwards is an error"

reset
XDG_FAIL=query ensure "$APP" text/plain
if ! { [[ "$rc" != 0 ]] && grep -q 'xdg-mime query failed: text/plain' "$scratch/out"; }; then die "a failing query must fail: rc=$rc: $(cat "$scratch/out")"; fi
log "ok: a failing xdg-mime query is an error"

reset
XDG_FAIL=default ensure "$APP" text/plain
if ! { [[ "$rc" != 0 ]] && grep -q 'xdg-mime default failed: text/plain' "$scratch/out"; }; then die "a failing set must fail: rc=$rc: $(cat "$scratch/out")"; fi
log "ok: a failing xdg-mime default is an error"
