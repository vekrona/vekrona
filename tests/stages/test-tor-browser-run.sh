#!/usr/bin/env bash
# `vekrona-tor-browser run` makes the launcher download over tor and start Tor Browser in a sandbox that has no network: python3 puts
# the current directory on sys.path for `-c`, and the sandbox may be started from a directory that holds files of somebody else, so the
# call must say -P. The tool runs here with stand-ins for flatpak, systemctl, id and inotifywait, and a copy whose lib/tor.sh names a
# socket this test makes. The program it hands to the sandbox runs here against a stand-in for the launcher and a stand-in for tor.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"

APP=org.torproject.torbrowser-launcher
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home" "$work/run"
export HOME="$work/home" XDG_RUNTIME_DIR="$work/run" FAKE_FLATPAK_LOG="$work/flatpak.log"
export FAKE_SYSTEMCTL_LOG="$work/systemctl.log" FAKE_INOTIFY_LOG="$work/inotify.log"
export FAKE_RUN_INSTANCE=4242 FAKE_RUN_STATUS=0
# The real inotifywait: the stand-in execs it for the cases that watch a real file.
REAL_INOTIFYWAIT="$(command -v inotifywait || true)"
[[ -n "$REAL_INOTIFYWAIT" ]] || die "the tests need inotifywait, which the tool runs too"
export REAL_INOTIFYWAIT
# The scope that flatpak makes for the sandbox of instance 4242, under the cgroup tree of the tool. It is not loaded unless a case names its
# cgroup in FAKE_CONTROLGROUP. FAKE_PROCS lists the pids in its cgroup and FAKE_EVENTS is its cgroup.events.
UNIT='app-flatpak-org.torproject.torbrowser\x2dlauncher-4242.scope'
SCOPE="/app.slice/$UNIT"
mkdir -p "$work/cgroup$SCOPE"
export FAKE_UNIT="$UNIT" FAKE_CONTROLGROUP="" FAKE_EVENTS="$work/cgroup$SCOPE/cgroup.events" FAKE_PROCS="$work/cgroup$SCOPE/cgroup.procs"
echo "populated 0" >"$FAKE_EVENTS"
: >"$FAKE_PROCS"
export FAKE_SOCKET="$work/socks"
SETTINGS="$HOME/.var/app/$APP/config/torbrowser/settings.json"

python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$work/socks"
mkdir -p "$work/root/bin" "$work/root/lib"
cp "$REPO/bin/vekrona-tor-browser" "$work/root/bin/"
cp "$REPO/lib/vekrona_tor_launch.py" "$work/root/lib/"
sed "s|^VEKRONA_TOR_SOCKET=.*|VEKRONA_TOR_SOCKET=$work/socks|" "$REPO/lib/tor.sh" >"$work/root/lib/tor.sh"
grep -q "^VEKRONA_TOR_SOCKET=$work/socks\$" "$work/root/lib/tor.sh" || die "the copy of lib/tor.sh does not name the test's socket"
tool="$work/root/bin/vekrona-tor-browser"
# The scope of a sandbox is found under the cgroup tree of the tool, which the test makes its own.
sed -i "s|^CGROUP_ROOT=.*|CGROUP_ROOT=$work/cgroup|" "$tool"
grep -q "^CGROUP_ROOT=$work/cgroup\$" "$tool" || die "the copy of the tool does not name the test's cgroup tree"

# The stand-in for flatpak run: it logs its arguments and writes FAKE_RUN_INSTANCE to the descriptor that --instance-id-fd names. With
# FAKE_STARTED set, it reports its start through that FIFO and blocks until it is stopped; otherwise it exits with FAKE_RUN_STATUS.
cat >"$work/bin/flatpak" <<'F'
#!/usr/bin/env bash
printf "%s\0" "$@" >>"$FAKE_FLATPAK_LOG"
for arg in "$@"; do
  [[ "$arg" != --instance-id-fd=* ]] || echo "$FAKE_RUN_INSTANCE" >&"${arg#--instance-id-fd=}"
done
if [[ -n "${FAKE_STARTED:-}" ]]; then
  echo started >"$FAKE_STARTED"
  exec sleep 600
fi
exit "$FAKE_RUN_STATUS"
F
printf '#!/usr/bin/env bash\n[[ "$1" == -nG ]] && echo vekrona-tor || exec /usr/bin/id "$@"\n' >"$work/bin/id"
# The stand-in for systemctl: tor.service of the system manager, and the scope of the sandbox of the user manager. `--user show -P
# ControlGroup UNIT` answers FAKE_CONTROLGROUP for FAKE_UNIT and nothing otherwise. `--user stop UNIT` ends the scope as systemd does: it
# kills the processes in FAKE_PROCS and empties FAKE_EVENTS. Every call is logged with the state of FAKE_EVENTS before it.
cat >"$work/bin/systemctl" <<'S'
#!/usr/bin/env bash
echo "$*|$(<"$FAKE_EVENTS")" >>"$FAKE_SYSTEMCTL_LOG"
if [[ "$1" == --user ]]; then
  case "$2" in
    show)
      if [[ -n "$FAKE_CONTROLGROUP" && "$5" == "$FAKE_UNIT" ]]; then echo "$FAKE_CONTROLGROUP"; fi
      ;;
    stop)
      while read -r pid; do kill -TERM "$pid" 2>/dev/null || true; done <"$FAKE_PROCS"
      echo "populated 0" >"$FAKE_EVENTS"
      ;;
  esac
fi
S
# The stand-in for inotifywait, for a watch of a socket (`--event create`) or of a cgroup.events file.
#  - A socket watch reports that it is armed on stderr, as inotifywait does, then does what FAKE_SOCKET_MODE says: appear makes the socket
#    and ends with 0, timeout ends with 2 (the watch ran out), fail ends with 1; unset, it ends with 0 at once.
#  - A cgroup watch logs its use, then reports that it is armed, then makes the kernel's flip of "populated" and closes the browser
#    (FAKE_CLOSE_PID). On a populated scope, FAKE_WATCH_SILENT blocks the watch before it reports anything, and FAKE_WATCH_BLOCKS blocks it
#    after it reported. A blocked watch tells the FIFO named by the variable that it waits, and ends only by a signal.
#  - FAKE_WATCH_REAL execs the real inotifywait instead, after telling the FIFO named by FAKE_WATCH_SIGNAL that it is about to watch.
cat >"$work/bin/inotifywait" <<'W'
#!/usr/bin/env bash
if [[ "$*" == *create* ]]; then
  echo "Setting up watches." >&2
  echo "Watches established." >&2
  case "${FAKE_SOCKET_MODE:-}" in
    appear) python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$FAKE_SOCKET" ;;
    timeout) exit 2 ;;
    fail) exit 1 ;;
  esac
  exit 0
fi
echo x >>"$FAKE_INOTIFY_LOG"
if [[ -n "${FAKE_WATCH_REAL:-}" ]]; then
  [[ -z "${FAKE_WATCH_SIGNAL:-}" ]] || echo armed >"$FAKE_WATCH_SIGNAL"
  exec "$REAL_INOTIFYWAIT" "$@"
fi
[[ -z "${FAKE_WATCH_SILENT:-}" ]] || { grep -qx "populated 1" "$FAKE_EVENTS" && { echo waiting >"$FAKE_WATCH_SILENT"; exec sleep 600; }; }
echo "Setting up watches." >&2
echo "Watches established." >&2
[[ -z "${FAKE_WATCH_BLOCKS:-}" ]] || { grep -qx "populated 1" "$FAKE_EVENTS" && { echo waiting >"$FAKE_WATCH_BLOCKS"; exec sleep 600; }; }
[[ -z "${FAKE_CLOSE_PID:-}" ]] || kill -KILL "$FAKE_CLOSE_PID" 2>/dev/null || true
echo "populated 0" >"$FAKE_EVENTS"
W
chmod +x "$work"/bin/*
export PATH="$work/bin:$PATH"

run_wrapper() {
  : >"$FAKE_FLATPAK_LOG"
  : >"$FAKE_SYSTEMCTL_LOG"
  : >"$FAKE_INOTIFY_LOG"
  bash "$tool" run "$@"
}
settings_json() { jq -c --sort-keys . "$SETTINGS"; }
# Reads the arguments that flatpak run got into argv, without the option that run passes first: the ID of the instance.
read_run_args() {
  mapfile -d "" -t argv <"$FAKE_FLATPAK_LOG"
  [[ "${argv[1]:-}" == --instance-id-fd=* ]] || die "run must have flatpak run write the ID of its instance, but flatpak got: ${argv[*]}"
  argv=("${argv[0]}" "${argv[@]:2}")
}
# Waits for the child $1 and dies unless it ended with the status $2; $3 says what that means.
expect_exit() {
  local status=0
  wait "$1" || status=$?
  [[ "$status" -eq "$2" ]] || die "$3, but it ended with $status"
}

run_wrapper || die "run failed with stand-ins for flatpak, systemctl and id"
read_run_args
# argv: run --command=python3 APP -P -c PROGRAM ADDRESS ARGS...
[[ "${argv[0]} ${argv[1]} ${argv[2]}" == "run --command=python3 $APP" ]] || die "run must start python3 in the sandbox of the launcher, but flatpak got: ${argv[*]:0:3}"
[[ "${argv[3]} ${argv[4]}" == "-P -c" ]] || die "run must start python3 with -P -c, but it started it with '${argv[3]} ${argv[4]}'"
script="${argv[5]}"
address="${argv[6]}"
[[ "$address" == 127.0.0.1:9050 ]] || die "run must name the proxy 127.0.0.1:9050 in the launcher's settings, but it names $address"
log "ok: python3 starts without the current directory on sys.path, running the launch program"
for arg in "${argv[@]}"; do [[ "$arg" != --share=* ]] || die "run must share nothing with the host, but it passed $arg"; done
log "ok: the sandbox of the launcher gets no network"

[[ "$(settings_json)" == "{\"download_over_tor\":true,\"tor_socks_address\":\"$address\"}" ]] \
  || die "a fresh settings file must make the launcher download over tor through $address, but it says: $(settings_json)"
log "ok: the launcher is set to download over tor through the proxy of the sandbox"

printf '{"mirror":"https://example.org/","download_over_tor":false,"force_en-US":true}' >"$SETTINGS"
run_wrapper || die "run failed with a settings file that has other keys"
[[ "$(settings_json)" == "{\"download_over_tor\":true,\"force_en-US\":true,\"mirror\":\"https://example.org/\",\"tor_socks_address\":\"$address\"}" ]] \
  || die "run must keep the other keys of the launcher's settings and set download over tor, but they are: $(settings_json)"
log "ok: the other settings of the launcher stay, and every run sets download over tor"

for content in '[]' '"text"' '{' ''; do
  printf '%s' "$content" >"$SETTINGS"
  if run_wrapper 2>"$work/stderr"; then die "run must refuse the settings file '$content', which is no JSON object"; fi
  grep -q 'cannot add the tor settings' "$work/stderr" || die "run did not say that the settings file '$content' is unusable: $(cat "$work/stderr")"
  [[ "$(<"$SETTINGS")" == "$content" ]] || die "run changed the settings file '$content' it refused"
  [[ "$(ls -A "$(dirname "$SETTINGS")")" == settings.json ]] || die "run left a temporary file next to the refused settings file '$content'"
  [[ ! -s "$FAKE_FLATPAK_LOG" ]] || die "run ran flatpak although the settings file '$content' was unusable"
done
log "ok: a settings file that is no JSON object is refused, untouched, and starts no sandbox"
# The last refusal left an empty file: the runs below need a settings file that is a JSON object again.
printf '{}' >"$SETTINGS"

# The arguments reach the launch program as they were given, each one as an argument of its own.
run_wrapper --help "https://example.org/a b" || die "run failed with stand-ins for flatpak, systemctl and id"
read_run_args
[[ ${#argv[@]} -eq 9 && "${argv[6]}" == 127.0.0.1:9050 && "${argv[7]}" == --help && "${argv[8]}" == "https://example.org/a b" ]] \
  || die "run must pass its arguments to the launch program after the proxy address, but flatpak got: ${argv[*]:6}"
log "ok: run hands its arguments to the launcher, one argument each"

# A scope that is not loaded has ended: run asks for its cgroup, waits for nothing, and stops tor.
run_wrapper || die "run failed when the scope of the sandbox is not loaded"
grep -qxF -- "--user show -P ControlGroup $UNIT|populated 0" "$FAKE_SYSTEMCTL_LOG" \
  || die "run must ask the user manager for the cgroup of the scope $UNIT, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "run must stop tor when the scope is not loaded, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ ! -s "$FAKE_INOTIFY_LOG" ]] || die "run must not watch a scope that is not loaded"
log "ok: a sandbox whose scope is not loaded has ended: run waits for nothing and stops tor"

# The launcher has ended, and its gpg agent, smart card daemon, dirmngr and keyboxd keep the scope populated while the browser runs on. Those
# four are stopped with TERM, the browser's processes are left alone, and run waits until the scope is empty, which the browser's close makes,
# before it stops tor.
for name in gpg-agent scdaemon dirmngr keyboxd firefox.real; do cp "$(command -v sleep)" "$work/$name"; done
"$work/gpg-agent" infinity & gpg_pid=$!
"$work/scdaemon" infinity & scd_pid=$!
"$work/dirmngr" infinity & dirmngr_pid=$!
"$work/keyboxd" infinity & keyboxd_pid=$!
"$work/firefox.real" infinity & browser_pid=$!
printf '%s\n' "$gpg_pid" "$scd_pid" "$dirmngr_pid" "$keyboxd_pid" "$browser_pid" >"$FAKE_PROCS"
echo "populated 1" >"$FAKE_EVENTS"
FAKE_CONTROLGROUP="$SCOPE" FAKE_CLOSE_PID="$browser_pid" run_wrapper || die "run failed while the scope of the browser is populated"
expect_exit "$gpg_pid" 143 "run must stop the gpg agent of the launcher with TERM"
expect_exit "$scd_pid" 143 "run must stop the smart card daemon of the launcher with TERM"
expect_exit "$dirmngr_pid" 143 "run must stop dirmngr of the launcher with TERM"
expect_exit "$keyboxd_pid" 143 "run must stop keyboxd of the launcher with TERM"
expect_exit "$browser_pid" 137 "run must leave the browser's processes alone, which only the stand-in's close (KILL, 137) ends"
[[ -s "$FAKE_INOTIFY_LOG" ]] || die "run must watch the scope until it is empty, but inotifywait was never asked"
grep -qF -- "--user stop" "$FAKE_SYSTEMCTL_LOG" && die "run must not stop the scope of a browser that closes by itself: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "run must stop tor once the scope is empty, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
log "ok: run ends the leftovers of the launcher, waits for the browser to close, and then stops tor"

# A TERM to run while it waits for the browser to close: the wait ends at once, the scope is stopped, which ends its processes, and then tor
# stops. The stand-in blocks its watch after it reported, and reports through a FIFO that it waits, so TERM is sent only once run waits.
mkfifo "$work/waiting"
exec {waiting}<>"$work/waiting"
"$work/gpg-agent" infinity & gpg_pid=$!
"$work/scdaemon" infinity & scd_pid=$!
"$work/firefox.real" infinity & browser_pid=$!
printf '%s\n' "$gpg_pid" "$scd_pid" "$browser_pid" >"$FAKE_PROCS"
echo "populated 1" >"$FAKE_EVENTS"
: >"$FAKE_SYSTEMCTL_LOG"
: >"$FAKE_INOTIFY_LOG"
FAKE_CONTROLGROUP="$SCOPE" FAKE_WATCH_BLOCKS="$work/waiting" bash "$tool" run >/dev/null 2>"$work/stderr" &
run_pid=$!
read -r -t 60 _ <&"$waiting" || { kill "$run_pid" 2>/dev/null || true; die "run did not wait for the browser within 60 s"; }
kill -TERM "$run_pid"
expect_exit "$run_pid" 143 "run must end with 143 when it gets TERM while it waits for the browser"
expect_exit "$gpg_pid" 143 "the scope must be stopped when run gets TERM while it waits, but the gpg agent ended otherwise"
expect_exit "$scd_pid" 143 "the scope must be stopped when run gets TERM while it waits, but the smart card daemon ended otherwise"
expect_exit "$browser_pid" 143 "the scope must be stopped when run gets TERM while it waits, but the browser ended otherwise"
grep -qxF -- "--user stop $UNIT|populated 1" "$FAKE_SYSTEMCTL_LOG" \
  || die "TERM while run waits must stop the scope while it is populated, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "TERM while run waits must stop tor after the scope is gone, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
exec {waiting}<&-
log "ok: TERM while run waits for the browser stops the scope, and then tor"

# A TERM while the watch of the browser's scope has reported nothing: the watch ends with no message, and run must still end on TERM, with
# the scope stopped and tor after it. The run is under timeout, the harness's bound on a run that does not end: it is killed then, and its
# status (137) fails the case. The FIFO says when the watch waits.
mkfifo "$work/silent"
exec {silent}<>"$work/silent"
"$work/gpg-agent" infinity & gpg_pid=$!
"$work/scdaemon" infinity & scd_pid=$!
"$work/firefox.real" infinity & browser_pid=$!
printf '%s\n' "$gpg_pid" "$scd_pid" "$browser_pid" >"$FAKE_PROCS"
echo "populated 1" >"$FAKE_EVENTS"
: >"$FAKE_SYSTEMCTL_LOG"
: >"$FAKE_INOTIFY_LOG"
FAKE_CONTROLGROUP="$SCOPE" FAKE_WATCH_SILENT="$work/silent" timeout --signal=KILL 60 bash "$tool" run >/dev/null 2>"$work/stderr" &
run_pid=$!
read -r -t 60 _ <&"$silent" || { kill "$run_pid" 2>/dev/null || true; die "run did not wait for the watch within 60 s"; }
kill -TERM "$run_pid"
expect_exit "$run_pid" 143 "run must end with 143 on TERM while its watch reports nothing"
expect_exit "$gpg_pid" 143 "the scope must be stopped when run gets TERM while its watch is silent, but the gpg agent ended otherwise"
expect_exit "$scd_pid" 143 "the scope must be stopped when run gets TERM while its watch is silent, but the smart card daemon ended otherwise"
expect_exit "$browser_pid" 143 "the scope must be stopped when run gets TERM while its watch is silent, but the browser ended otherwise"
grep -qxF -- "--user stop $UNIT|populated 1" "$FAKE_SYSTEMCTL_LOG" \
  || die "TERM while the watch is silent must stop the scope while it is populated, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "TERM while the watch is silent must stop tor after the scope is gone, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
exec {silent}<&-
log "ok: TERM while the watch reports nothing still ends run, after the scope is stopped and before tor is"

# A TERM to run while flatpak run runs stops the scope, which ends its processes, and then stops tor. The stand-in for flatpak run reports
# its start through a FIFO, so TERM is sent only once flatpak run runs.
mkfifo "$work/started"
exec {started}<>"$work/started"
"$work/gpg-agent" infinity & gpg_pid=$!
"$work/scdaemon" infinity & scd_pid=$!
"$work/firefox.real" infinity & browser_pid=$!
printf '%s\n' "$gpg_pid" "$scd_pid" "$browser_pid" >"$FAKE_PROCS"
echo "populated 1" >"$FAKE_EVENTS"
: >"$FAKE_SYSTEMCTL_LOG"
FAKE_CONTROLGROUP="$SCOPE" FAKE_STARTED="$work/started" bash "$tool" run >/dev/null 2>"$work/stderr" &
run_pid=$!
read -r -t 60 _ <&"$started" || { kill "$run_pid" 2>/dev/null || true; die "run did not start flatpak run within 60 s"; }
kill -TERM "$run_pid"
expect_exit "$run_pid" 143 "run must end with 143 when it gets TERM while flatpak run runs"
expect_exit "$gpg_pid" 143 "the scope must be stopped when run gets TERM, but the gpg agent ended otherwise"
expect_exit "$scd_pid" 143 "the scope must be stopped when run gets TERM, but the smart card daemon ended otherwise"
expect_exit "$browser_pid" 143 "the scope must be stopped when run gets TERM, but the browser ended otherwise"
grep -qxF -- "--user stop $UNIT|populated 1" "$FAKE_SYSTEMCTL_LOG" \
  || die "TERM to run must stop the scope while it is populated, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "TERM to run must stop tor after the scope is gone, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
exec {started}<&-
log "ok: TERM to run stops the scope, which ends its processes, and then stops tor"

# Two runs share tor. The first run's browser closes while the second still runs: tor must stay up until the second run ends, and then be
# stopped once. Both watches are the real inotifywait, which the test wakes by writing the scope's cgroup.events. Each run tells the FIFO
# that it is about to watch, so both hold their tor references before the first browser closes.
UNIT_B='app-flatpak-org.torproject.torbrowser\x2dlauncher-4243.scope'
SCOPE_B="/app.slice/$UNIT_B"
mkdir -p "$work/cgroup$SCOPE_B"
EVENTS_B="$work/cgroup$SCOPE_B/cgroup.events"
PROCS_B="$work/cgroup$SCOPE_B/cgroup.procs"
echo "populated 1" >"$FAKE_EVENTS"
echo "populated 1" >"$EVENTS_B"
: >"$FAKE_PROCS"
: >"$PROCS_B"
mkfifo "$work/armed-a" "$work/armed-b"
exec {armed_a}<>"$work/armed-a" {armed_b}<>"$work/armed-b"
: >"$FAKE_SYSTEMCTL_LOG"
FAKE_RUN_INSTANCE=4242 FAKE_UNIT="$UNIT" FAKE_CONTROLGROUP="$SCOPE" FAKE_EVENTS="$FAKE_EVENTS" FAKE_PROCS="$FAKE_PROCS" \
  FAKE_WATCH_REAL=1 FAKE_WATCH_SIGNAL="$work/armed-a" timeout --signal=KILL 60 bash "$tool" run >/dev/null 2>"$work/stderr-a" &
first_pid=$!
FAKE_RUN_INSTANCE=4243 FAKE_UNIT="$UNIT_B" FAKE_CONTROLGROUP="$SCOPE_B" FAKE_EVENTS="$EVENTS_B" FAKE_PROCS="$PROCS_B" \
  FAKE_WATCH_REAL=1 FAKE_WATCH_SIGNAL="$work/armed-b" timeout --signal=KILL 60 bash "$tool" run >/dev/null 2>"$work/stderr-b" &
second_pid=$!
read -r -t 60 _ <&"$armed_a" || { kill "$first_pid" "$second_pid" 2>/dev/null || true; die "the first run did not watch its scope within 60 s"; }
read -r -t 60 _ <&"$armed_b" || { kill "$first_pid" "$second_pid" 2>/dev/null || true; die "the second run did not watch its scope within 60 s"; }
echo "populated 0" >"$FAKE_EVENTS"
expect_exit "$first_pid" 0 "the first run must end with 0 once its browser has closed"
grep -q '^stop tor.service' "$FAKE_SYSTEMCTL_LOG" && die "tor must stay up while the second run still runs, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
echo "populated 0" >"$EVENTS_B"
expect_exit "$second_pid" 0 "the second run must end with 0 once its browser has closed"
[[ "$(grep -c '^stop tor.service' "$FAKE_SYSTEMCTL_LOG")" -eq 1 ]] \
  || die "tor must be stopped exactly once, when the second run ends, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "the stop of tor must come after the second run's scope is gone, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
exec {armed_a}<&- {armed_b}<&-
log "ok: tor stays up while a second run uses it, and is stopped once, when the last run ends"

# A scope whose cgroup directory is gone has ended: no process of it is left, and run waits for nothing and stops tor. The real inotifywait
# cannot watch a file that is gone, which is the failure the tool must take as the end.
FAKE_WATCH_REAL=1 FAKE_CONTROLGROUP=/app.slice/gone-scope run_wrapper || die "run must end when the cgroup of its scope is gone"
[[ "$(tail -n 1 "$FAKE_SYSTEMCTL_LOG")" == "stop tor.service|populated 0" ]] \
  || die "run must stop tor when the cgroup of its scope is gone, but systemctl was asked: $(<"$FAKE_SYSTEMCTL_LOG")"
log "ok: a scope whose cgroup is gone has ended: run stops tor and waits for nothing"

# The status of flatpak run is the status of run, whether or not there was a scope to wait for.
status=0
FAKE_RUN_STATUS=7 run_wrapper || status=$?
[[ "$status" -eq 7 ]] || die "run must end with the status of flatpak run, 7, but it ended with $status"
log "ok: run ends with the status of flatpak run"

# A flatpak run that made no instance has nothing to end; a status of 0 without an instance is a failure of the tool, not a success.
if FAKE_RUN_INSTANCE= run_wrapper 2>"$work/stderr"; then die "run must fail when flatpak run made no instance"; fi
grep -q 'made no instance' "$work/stderr" || die "run did not say that flatpak run made no instance: $(cat "$work/stderr")"
log "ok: run fails when flatpak run names no instance"

# tor makes its socket after it says it is ready. The directory is watched from before the socket is tested, so a socket that appears
# after the watch is armed is the watch's event: run goes on once it is there.
rm -f "$work/socks"
FAKE_SOCKET_MODE=appear run_wrapper --help || die "run must go on once tor's socket appears"
[[ -S "$work/socks" ]] || die "the socket must have appeared for run to go on"
[[ -s "$FAKE_FLATPAK_LOG" ]] || die "run must start the browser once tor's socket is up"
log "ok: run waits for the socket of tor, watched, and goes on once it appears"

# tor makes no socket within the bound: the watch runs out (status 2), and run says so, and starts no browser.
rm -f "$work/socks"
if FAKE_SOCKET_MODE=timeout run_wrapper --help 2>"$work/stderr"; then die "run must fail when tor makes no socket within the bound"; fi
grep -q 'made no socket at .* within 30 s' "$work/stderr" || die "run did not say that tor made no socket within the bound: $(cat "$work/stderr")"
[[ ! -s "$FAKE_FLATPAK_LOG" ]] || die "run must not start the browser without tor's socket"
log "ok: run fails with the reason when tor makes no socket within the bound"

rm -f "$work/socks"
if FAKE_SOCKET_MODE=fail run_wrapper --help 2>"$work/stderr"; then die "run must fail when inotifywait fails"; fi
grep -q 'failed with status 1' "$work/stderr" || die "run did not say that inotifywait failed: $(cat "$work/stderr")"
log "ok: run fails with the reason when the watch of the socket fails"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$work/socks"

printf '%s' "$script" >"$work/launch.py"
python3 -P - "$work/launch.py" "$address" <<'PY' || die "the launch program does not relay the launcher's download to tor, or does not end as the launcher does"
"""Runs the launch program against a stand-in for torbrowser_launcher and a stand-in for the unix socket of tor."""

import json
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading

script = pathlib.Path(sys.argv[1]).read_text()
address = sys.argv[2]
work = pathlib.Path(tempfile.mkdtemp())
ARGS = ["--help", "https://example.org/a b"]

package = work / "modules" / "torbrowser_launcher"
package.mkdir(parents=True)
(package / "launcher.py").write_text(
    """
import os
import sys


def record(event):
    with open(os.environ["FAKE_OUT"] + ".started", "a") as started:
        started.write(event + " ")


class Launcher:
    # The launcher's own tasks, unpatched: the launch program must not let the error dialogs relaunch anything, and the browser starts.
    def run(self):
        record("run")
        sys.exit(int(os.environ["FAKE_RUN_STATUS"]))

    def try_tor(self):
        record("try_tor")

    def try_default_mirror(self):
        record("try_default_mirror")
"""
)
(package / "__init__.py").write_text(
    """
import json
import os
import socket
import struct
import sys

from torbrowser_launcher import launcher


class Window:
    def close(self):
        with open(os.environ["FAKE_OUT"] + ".closed", "a") as closed:
            closed.write("closed ")


def proxy_address():
    return (os.environ["FAKE_HOST"], int(os.environ["FAKE_PORT"]))


# The download: a request through the proxy the settings name, answered by tor.
def exchange(request):
    with socket.create_connection(proxy_address()) as proxy:
        proxy.sendall(request)
        proxy.shutdown(socket.SHUT_WR)
        reply = b""
        while chunk := proxy.recv(100):
            reply += chunk
    return reply


# The launcher resets a connection when it is done with it.
def reset(request):
    with socket.create_connection(proxy_address()) as proxy:
        proxy.sendall(request)
        proxy.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))


def main():
    assert sys.argv[1:] == json.loads(os.environ["FAKE_ARGS"]), "the launcher must get the arguments of run: " + repr(sys.argv)
    if os.environ["FAKE_MODE"] == "crash":
        raise RuntimeError("the launcher failed")
    first = exchange(b"ping")
    reset(b"reset")
    # Tor serves one connection at a time, so this one is answered once the reset one has been shut down.
    second = exchange(b"ping again")
    with open(os.environ["FAKE_OUT"], "wb") as out:
        out.write(first)
    with open(os.environ["FAKE_OUT"] + ".second", "wb") as out:
        out.write(second)
    # The two error dialogs that relaunch the launcher, then the browser's start.
    launcher.Launcher.try_tor(Window())
    launcher.Launcher.try_default_mirror(Window())
    launcher.Launcher().run()
"""
)

tor_path = work / "socks"
tor = socket.socket(socket.AF_UNIX)
tor.bind(str(tor_path))
tor.listen()


def stand_in_for_tor():
    while True:
        connection, _ = tor.accept()
        with connection:
            request = b""
            while chunk := connection.recv(100):
                request += chunk
            connection.sendall(b"answer to " + request)


threading.Thread(target=stand_in_for_tor, daemon=True).start()

host = address.rpartition(":")[0]
# The program listens on a free port instead of the one of the settings, so that a service on this machine is not in the way.
probe = socket.socket()
probe.bind((host, 0))
port = probe.getsockname()[1]
probe.close()


# Each run has a directory of its own for its outputs; the launch program ends with the launcher's status.
def run(mode, status):
    run_dir = work / mode
    run_dir.mkdir()
    env = dict(
        os.environ,
        PYTHONPATH=str(work / "modules"),
        TOR_SOCKS_IPC_PATH=str(tor_path),
        FAKE_HOST=host,
        FAKE_PORT=str(port),
        FAKE_OUT=str(run_dir / "out"),
        FAKE_MODE=mode,
        FAKE_RUN_STATUS=str(status),
        FAKE_ARGS=json.dumps(ARGS),
    )
    finished = subprocess.run(
        [sys.executable, "-P", "-c", script, f"{host}:{port}", *ARGS], env=env, capture_output=True, text=True, timeout=30
    )
    return finished, run_dir


finished, run_dir = run("download", 7)
assert finished.returncode == 7, f"the launch program must end with the launcher's status, 7, but it ended with {finished.returncode}: {finished.stderr}"
assert finished.stderr == "", f"the relay must end quietly when a connection is reset, but the launch program wrote: {finished.stderr}"
assert (run_dir / "out").read_bytes() == b"answer to ping", "the proxy must hand the connection to tor"
assert (run_dir / "out.second").read_bytes() == b"answer to ping again", "a connection after a reset must still reach tor"
assert (run_dir / "out.started").read_text() == "run ", "the launcher must start Tor Browser, and the error dialogs must not relaunch: " + (run_dir / "out.started").read_text()
assert (run_dir / "out.closed").read_text() == "closed " * 2, "each error dialog must close its window instead of relaunching the launcher"

crashed, _ = run("crash", 0)
assert crashed.returncode == 1 and "the launcher failed" in crashed.stderr, (
    f"a launcher that fails must fail the program, got {crashed.returncode}: {crashed.stderr}"
)
PY
log "ok: the launch program relays the download to tor and ends with the launcher's status"
