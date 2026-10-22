#!/usr/bin/env bash
set -euo pipefail

# Every tool in bin/ that has a side effect needs an explicit verb. A bare call (a quoting slip that runs a file list as
# commands, a loop over bin/*, a completion) prints its usage, exits 2 and touches nothing. One test covers the whole
# directory, so a new tool that acts without a verb fails here.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# The tools that act bare on purpose: they only print, and the Sway environment file sources them without arguments.
declare -A EXEMPT=(
  [vekrona-gpu-env]="prints the WLR_DRM_DEVICES assignment that config/sway/environment sources at every login"
  [vekrona-xkb-env]="prints the XKB_DEFAULT_* assignments that config/sway/environment sources at every login"
)

# The commands through which a bare call could change the machine. Each one records its name and fails.
TRIPWIRES=(
  systemctl systemd-run systemd-inhibit systemd-notify sudo loginctl busctl gdbus qs swaymsg swayidle slurp grim wf-recorder
  wl-copy notify-send rofi pw-dump wpctl snapper dnf5 flatpak curl firefox ghostty gsettings dbus-run-session vdirsyncer khal
)

# The only programs a tool may find before it checks its arguments: the interpreters its shebang names and what lib/common.sh,
# lib/vekrona_cli.py and the usage messages use. A tool that needs another one before its usage check fails with "command not
# found", and the author adds it here on purpose.
ALLOWED=(bash env python3 cat grep sed tail dirname basename readlink id)

# A tool that blocks on a refused call is a failure of its own, so each run has a deadline. It is no pause.
DEADLINE_SEC=10

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
tripped="$scratch/tripped"
mkdir -p "$stubs"
: >"$tripped"

for command in "${ALLOWED[@]}"; do
  found="$(type -P "$command")" || die "$command is needed by the bare-call test but is not on PATH"
  ln -s "$found" "$stubs/$command"
done

for command in "${TRIPWIRES[@]}"; do
  write_fake "$stubs/$command" <<'F'
#!/usr/bin/env bash
echo "${0##*/} $*" >>"$TRIPWIRE_LOG"
exit 1
F
done

# One scratch home for HOME and every XDG directory, so that anything a tool writes shows in the listing.
home="$scratch/home"
mkdir -p "$home/run"
chmod 700 "$home/run"
# Nothing of the caller's environment reaches a tool: no session bus, no Sway or Wayland socket, no login session, and a PATH of
# the tripwires and the allowed programs only, so that the user's own ~/.local/bin/vekrona-* and every command that is not
# stubbed are out of reach. The bus address points nowhere, as in tests/lib.sh.
sandbox=(env -i
  PATH="$stubs" LANG=C.UTF-8 HOME="$home" XDG_RUNTIME_DIR="$home/run"
  XDG_CONFIG_HOME="$home/.config" XDG_STATE_HOME="$home/.local/state" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache"
  DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent/vekrona-test-session-bus
  VEKRONA_ERROR_REPORTER=/usr/bin/true VEKRONA_JOURNAL_SOCKET=/nonexistent/vekrona-test-journal-socket
  TRIPWIRE_LOG="$tripped")
snapshot_home() { find "$home" -printf '%p %y %s %T@\n' | sort; }

for name in "${!EXEMPT[@]}"; do
  [[ -x "$ROOT/bin/$name" ]] || die "$name is exempt from the bare-call rule but bin/$name does not exist: drop it from EXEMPT"
done

run_bare() {
  local tool="$1" before
  before="$(snapshot_home)"
  : >"$tripped"
  rc=0
  timeout "$DEADLINE_SEC" "${sandbox[@]}" "$ROOT/bin/$tool" </dev/null >/dev/null 2>"$scratch/stderr" || rc=$?
  [[ ! -s "$tripped" ]] || die "$tool: a bare call ran $(head -n 1 "$tripped")"
  [[ "$(snapshot_home)" == "$before" ]] || die "$tool: a bare call changed the home directory"
}

checked=0
for path in "$ROOT"/bin/*; do
  [[ -f "$path" && -x "$path" ]] || continue
  tool="${path##*/}"
  run_bare "$tool"
  if [[ -n "${EXEMPT[$tool]-}" ]]; then
    continue
  fi
  [[ "$rc" != 124 ]] || die "$tool: a bare call did not end within ${DEADLINE_SEC}s"
  [[ "$rc" == 2 ]] || die "$tool: a bare call must be refused with exit 2, got $rc: $(cat "$scratch/stderr")"
  grep -qi 'usage' "$scratch/stderr" || die "$tool: a bare call must print its usage on stderr: $(cat "$scratch/stderr")"
  checked=$((checked + 1))
done
((checked > 0)) || die "no tool in bin/ was checked"
log "ok: a bare call of each of the $checked tools in bin/ prints its usage, exits 2 and changes nothing"
log "ok: the ${#EXEMPT[@]} tools that only print are exempt and still change nothing"
