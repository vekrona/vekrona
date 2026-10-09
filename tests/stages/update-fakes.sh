#!/usr/bin/env bash
# A fake machine for the update pipeline tests (source it after tests/lib.sh). make_world DIR puts command stubs first
# on PATH and points every state path of the scripts into DIR. Tests set the machine up through the files named below,
# and read what the scripts did from $FAKE_LOG, one line per call.
#
#   sessions/ID          logind session ID, "Key=Value" lines (add_session)
#   inhibitors           what `systemd-inhibit --list` prints (systemd-inhibit's table rows)
#   units/UNIT.active    exists while the unit is active
#   dnf.json, dnf.rc     what `dnf5 check-upgrade --json` prints, and the exit status of check-upgrade: 0 nothing,
#                        100 updates (plain output only; --json exits 0 then, as dnf5 does), anything else a failure
#   upgrade.rc           exit status of `dnf5 upgrade`
#   notify.fails         exists while notify-send fails
#   flatpak.tsv, mise.json, installed.tsv   what flatpak remote-ls, mise outdated and rpm -qa print
#   offline.status       what `dnf5 offline status` prints; `dnf5 upgrade --offline` stores a transaction unless
#                        offline.empty exists (dnf skipped everything check-upgrade listed)
#   answer               what vekrona-update-ask prints
#
# The scripts insist on root, which a user namespace that maps the caller to uid 0 gives them (run_as_root).

unshare -r true || die "cannot create a user namespace to stand in for root"

make_world() {
  local w="$1"
  mkdir -p "$w/bin" "$w/sessions" "$w/units" "$w/state" "$w/repos" "$w/mise"
  : >"$w/log"
  : >"$w/inhibitors"
  echo '{}' >"$w/dnf.json"
  echo 0 >"$w/dnf.rc"
  echo 0 >"$w/upgrade.rc"
  : >"$w/flatpak.tsv"
  echo '{}' >"$w/mise.json"
  : >"$w/installed.tsv"
  echo "No offline transaction is stored." >"$w/offline.status"
  echo timeout >"$w/answer"
  cat >"$w/bin/loginctl" <<'F'
#!/usr/bin/env bash
case "$1" in
  list-sessions) for f in "$FAKE_WORLD"/sessions/*; do [[ -e "$f" ]] && echo "${f##*/} 1000 someone seat0 100 user tty1 no -"; done; exit 0 ;;
  show-session)
    id="$2"; shift 2
    while [[ $# -gt 0 ]]; do [[ "$1" == -p ]] && grep "^$2=" "$FAKE_WORLD/sessions/$id"; shift 2; done
    ;;
esac
F
  cat >"$w/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$FAKE_WORLD/log"
case "$1" in
  is-active) if [[ -e "$FAKE_WORLD/units/$2.active" ]]; then echo active; else echo inactive; exit 3; fi ;;
  start) touch "$FAKE_WORLD/units/$2.active" ;;
  stop) rm -f "$FAKE_WORLD/units/$2.active" ;;
esac
F
  cat >"$w/bin/systemd-inhibit" <<'F'
#!/usr/bin/env bash
cat "$FAKE_WORLD/inhibitors"
F
  cat >"$w/bin/runuser" <<'F'
#!/usr/bin/env bash
# runuser -u NAME -- env VAR=VALUE... COMMAND ARGS...
echo "runuser $*" >>"$FAKE_WORLD/log"
shift 3
[[ "$1" == env ]] && shift
while [[ "$1" == *=* ]]; do shift; done
case "${1##*/}" in
  vekrona-update-ask) cat "$FAKE_WORLD/answer" ;;
  notify-send) [[ ! -e "$FAKE_WORLD/notify.fails" ]] || exit 1 ;;
  *) echo "runuser stub: unexpected command $1" >&2; exit 99 ;;
esac
F
  cat >"$w/bin/dnf5" <<'F'
#!/usr/bin/env bash
echo "dnf5 $*" >>"$FAKE_WORLD/log"
case "$1" in
  check-upgrade) rc="$(<"$FAKE_WORLD/dnf.rc")"
                 if [[ " $* " == *" --json "* ]]; then cat "$FAKE_WORLD/dnf.json"; [[ "$rc" -ne 100 ]] || rc=0; fi
                 exit "$rc" ;;
  upgrade) if flock --nonblock "$VEKRONA_UPDATE_LOCK" true; then echo "dnf5 ran without the update lock" >>"$FAKE_WORLD/log"; fi
           if [[ " $* " == *" --offline "* && ! -e "$FAKE_WORLD/offline.empty" ]]; then
             echo "An offline transaction was initiated on today." >"$FAKE_WORLD/offline.status"
           fi
           exit "$(<"$FAKE_WORLD/upgrade.rc")" ;;
  offline) case "$2" in status) cat "$FAKE_WORLD/offline.status" ;; log) echo "offline log line" ;; esac ;;
esac
F
  cat >"$w/bin/rpm" <<'F'
#!/usr/bin/env bash
cat "$FAKE_WORLD/installed.tsv"
F
  cat >"$w/bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$FAKE_WORLD/log"
[[ "$1" != remote-ls ]] || cat "$FAKE_WORLD/flatpak.tsv"
F
  cat >"$w/bin/mise" <<'F'
#!/usr/bin/env bash
echo "mise $*" >>"$FAKE_WORLD/log"
[[ "$1" != outdated ]] || cat "$FAKE_WORLD/mise.json"
F
  cat >"$w/bin/snapper" <<'F'
#!/usr/bin/env bash
echo "snapper $*" >>"$FAKE_WORLD/log"
if [[ " $* " == *" --pre-number "* ]]; then echo 11; else echo 10; fi
F
  cat >"$w/bin/vekrona-proton" <<'F'
#!/usr/bin/env bash
echo "vekrona-proton $*" >>"$FAKE_WORLD/log"
F
  chmod +x "$w/bin/"*
  export PATH="$w/bin:$PATH" FAKE_WORLD="$w" FAKE_LOG="$w/log" \
    VEKRONA_STATE_DIR="$w/state" VEKRONA_UPDATE_LOCK="$w/lock" VEKRONA_PROTON="$w/bin/vekrona-proton" \
    VEKRONA_YUM_REPOS_DIR="$w/repos" VEKRONA_SYSTEMD_UNIT_DIR="$w/units-installed" MISE_SYSTEM_DATA_DIR="$w/mise"
}

# add_session ID KEY=VALUE...: a logind session that is, unless said otherwise, an awake Wayland user's.
add_session() {
  local id="$1"
  shift
  printf '%s\n' Type=wayland Active=yes LockedHint=no IdleHint=no Name=someone User=1000 "$@" >"$FAKE_WORLD/sessions/$id"
}

run_as_root() { unshare -r "$@"; }
log_lines() { grep -c -- "$1" "$FAKE_LOG" || true; }
