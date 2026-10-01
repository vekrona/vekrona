SESSION_SWAY_UNIT="vekrona-sway-session"

XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export XDG_RUNTIME_DIR

SESSION_OWNED_MARKER="$XDG_RUNTIME_DIR/vekrona-vm-test-session-owned"

session_wait_until() {
  local timeout="$1" deadline; shift
  deadline=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || return 1
    inotifywait -qq -t 1 -e create,modify,moved_to "$XDG_RUNTIME_DIR" >/dev/null 2>&1 || true
  done
}

session_resolve_swaysock() {
  local sock
  sock="$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -regextype posix-extended \
    -regex '.*/sway-ipc\.[0-9]+\.[0-9]+\.sock' 2>/dev/null | head -1)"
  [[ -n "$sock" && -S "$sock" ]] || return 1
  printf '%s' "$sock"
}

# Attaches to whatever live session is already running (this VM is shared
# across test runs, and a human or another check may already be logged in
# and watching it over virt-viewer: never start a second compositor, or
# stop the live one, while that is the case). Exports SWAYSOCK on success.
session_attach_existing() {
  pgrep -x sway >/dev/null || return 1
  local sock
  sock="$(session_resolve_swaysock)" || return 1
  swaymsg -t get_version >/dev/null 2>&1 || return 1
  [[ "$(systemctl --user is-active sway-session.target 2>/dev/null || true)" == active ]] || return 1
  SWAYSOCK="$sock"
  export SWAYSOCK
}

session_start_new() {
  systemctl --user reset-failed "$SESSION_SWAY_UNIT" >/dev/null 2>&1 || true
  find "$XDG_RUNTIME_DIR" -maxdepth 1 -regextype posix-extended \
    -regex '.*/sway-ipc\.[0-9]+\.[0-9]+\.sock' -delete

  coproc SESSION_SWAY_WATCH {
    inotifywait -e create --include 'sway-ipc\.[0-9]+\.[0-9]+\.sock$' \
      --format '%f' -t 60 "$XDG_RUNTIME_DIR" 2>&1
  }
  local watch_line
  IFS= read -r -u "${SESSION_SWAY_WATCH[0]}" watch_line
  if [[ "$watch_line" != "Watches established." ]]; then
    echo "session-lib: could not set up the sway ipc socket watch" >&2
    return 1
  fi

  if ! systemd-run --user --unit "$SESSION_SWAY_UNIT" \
    --setenv=WLR_BACKENDS=headless --setenv=WLR_LIBINPUT_NO_DEVICES=1 \
    -- sway -c "$HOME/.config/sway/config" --unsupported-gpu; then
    echo "session-lib: could not start sway via systemd-run" >&2
    return 1
  fi

  local sockname
  if ! IFS= read -r -u "${SESSION_SWAY_WATCH[0]}" sockname; then
    echo "session-lib: sway ipc socket never appeared" >&2
    return 1
  fi
  SWAYSOCK="$XDG_RUNTIME_DIR/$sockname"
  export SWAYSOCK
  if [[ ! -S "$SWAYSOCK" ]]; then
    echo "session-lib: sway ipc socket not found: $SWAYSOCK" >&2
    return 1
  fi

  if ! swaymsg -t get_version >/dev/null; then
    echo "session-lib: swaymsg get_version failed" >&2
    return 1
  fi

  if ! systemctl --user start sway-session.target; then
    echo "session-lib: sway-session.target did not become active" >&2
    return 1
  fi
  if [[ "$(systemctl --user is-active sway-session.target 2>/dev/null || true)" != active ]]; then
    echo "session-lib: sway-session.target not active" >&2
    return 1
  fi

  : > "$SESSION_OWNED_MARKER"
}

# Idempotent: attaches to a session that is already up (another check's own
# session_start_new, or a live login someone is watching), only starting a
# new headless one when nothing is running at all.
session_ensure_up() {
  if session_attach_existing; then
    echo "session-lib: attached to an already-running sway session" >&2
    return 0
  fi
  if pgrep -x sway >/dev/null; then
    echo "session-lib: a sway process is running but has no live IPC socket or sway-session.target is not active; refusing to touch it" >&2
    return 1
  fi
  session_start_new
}

# Only stops the session this test run itself started (session_start_new);
# a session we merely attached to (session_attach_existing) is left alone.
session_teardown() {
  if [[ -e "$SESSION_OWNED_MARKER" ]]; then
    systemctl --user stop sway-session.target >/dev/null 2>&1 || true
    systemctl --user stop "$SESSION_SWAY_UNIT" >/dev/null 2>&1 || true
    rm -f "$SESSION_OWNED_MARKER"
  else
    echo "session-lib: this test run did not start the live session; leaving it running" >&2
  fi
}
