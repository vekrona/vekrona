#!/usr/bin/env bash
# `vekrona-tor-browser install` makes the launcher download over tor and runs it in a sandbox that has no network: python3 puts the
# current directory on sys.path for `-c`, and the sandbox may be started from a directory that holds files of somebody else, so the
# call must say -P. The tool runs here with stand-ins for flatpak, systemctl and id, and a copy whose lib/tor.sh names a socket this
# test makes. The program it hands to the sandbox runs here against a stand-in for the launcher and a stand-in for tor.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/home" "$work/run"
export HOME="$work/home" XDG_RUNTIME_DIR="$work/run" FAKE_FLATPAK_LOG="$work/flatpak.log"
export FAKE_PS_LOG="$work/ps.log" FAKE_PS_COUNT="$work/ps.count"
echo 0 >"$FAKE_PS_COUNT"
FAKE_GONE_PID="$(bash -c 'echo $$')"
export FAKE_GONE_PID
SETTINGS="$HOME/.var/app/org.torproject.torbrowser-launcher/config/torbrowser/settings.json"

python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$work/socks"
mkdir -p "$work/root/bin" "$work/root/lib"
cp "$REPO/bin/vekrona-tor-browser" "$work/root/bin/"
cp "$REPO/lib/vekrona_tor_install.py" "$work/root/lib/"
sed "s|^VEKRONA_TOR_SOCKET=.*|VEKRONA_TOR_SOCKET=$work/socks|" "$REPO/lib/tor.sh" >"$work/root/lib/tor.sh"
grep -q "^VEKRONA_TOR_SOCKET=$work/socks\$" "$work/root/lib/tor.sh" || die "the copy of lib/tor.sh does not name the test's socket"
tool="$work/root/bin/vekrona-tor-browser"

# `flatpak ps` is not logged (the log holds the arguments of the runs); it lists an instance of the app while FAKE_PS_COUNT holds a number
# above 0 and counts it down, with the pid of a process that is gone.
cat >"$work/bin/flatpak" <<'F'
#!/usr/bin/env bash
if [[ "$1" == ps ]]; then
  echo "x" >>"$FAKE_PS_LOG"
  if (($(<"$FAKE_PS_COUNT") > 0)); then
    echo $(($(<"$FAKE_PS_COUNT") - 1)) >"$FAKE_PS_COUNT"
    printf 'org.torproject.torbrowser-launcher\t%s\n' "$FAKE_GONE_PID"
  fi
  exit 0
fi
printf "%s\0" "$@" >>"$FAKE_FLATPAK_LOG"
F
printf '#!/usr/bin/env bash\n[[ "$1" == -nG ]] && echo vekrona-tor || exec /usr/bin/id "$@"\n' >"$work/bin/id"
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/systemctl"
chmod +x "$work"/bin/*
export PATH="$work/bin:$PATH"

# Runs install; the stand-in for flatpak logs its arguments each ended by a NUL, since the program among them has lines.
run_install() {
  : >"$FAKE_FLATPAK_LOG"
  bash "$tool" install
}
settings_json() { jq -c --sort-keys . "$SETTINGS"; }

run_install || die "install failed with stand-ins for flatpak, systemctl and id"
mapfile -d "" -t argv <"$FAKE_FLATPAK_LOG"
# argv: run --command=python3 APP FLAG... SCRIPT ADDRESS
[[ "${argv[0]} ${argv[1]}" == "run --command=python3" ]] || die "install ran flatpak with another shape: ${argv[*]:0:2}"
[[ "${argv[3]}" == -P && "${argv[4]}" == -c ]] || die "install must start python3 with -P -c, but it started it with '${argv[3]} ${argv[4]}'"
script="${argv[5]}"
address="${argv[6]}"
log "ok: python3 starts without the current directory on sys.path"
for arg in "${argv[@]}"; do [[ "$arg" != --share=* ]] || die "install must share nothing with the host, but it passed $arg"; done
log "ok: the sandbox of the install run gets no network"

[[ "$(settings_json)" == "{\"download_over_tor\":true,\"tor_socks_address\":\"$address\"}" ]] \
  || die "a fresh settings file must make the launcher download over tor through $address, but it says: $(settings_json)"
log "ok: the launcher is set to download over tor through the address the sandbox listens on"

printf '{"mirror":"https://example.org/","download_over_tor":false,"force_en-US":true}' >"$SETTINGS"
run_install || die "install failed with a settings file that has other keys"
[[ "$(settings_json)" == "{\"download_over_tor\":true,\"force_en-US\":true,\"mirror\":\"https://example.org/\",\"tor_socks_address\":\"$address\"}" ]] \
  || die "install must keep the other keys of the launcher's settings, but they are: $(settings_json)"
log "ok: the other settings of the launcher stay"

for content in '[]' '"text"' '{' ''; do
  printf '%s' "$content" >"$SETTINGS"
  if run_install 2>"$work/stderr"; then die "install must refuse the settings file '$content', which is no JSON object"; fi
  grep -q 'cannot add the tor settings' "$work/stderr" || die "install did not say that the settings file '$content' is unusable: $(cat "$work/stderr")"
  [[ "$(<"$SETTINGS")" == "$content" ]] || die "install changed the settings file '$content' it refused"
  [[ "$(ls -A "$(dirname "$SETTINGS")")" == settings.json ]] || die "install left a temporary file next to the refused settings file '$content'"
  [[ ! -s "$FAKE_FLATPAK_LOG" ]] || die "install ran flatpak although the settings were unusable"
done
log "ok: a settings file that is no JSON object is refused, untouched, and starts no sandbox"

: >"$FAKE_FLATPAK_LOG"
bash "$tool" run --help https://example.org || die "run failed with stand-ins for flatpak, systemctl and id"
mapfile -d "" -t argv <"$FAKE_FLATPAK_LOG"
[[ "${argv[*]}" == "run org.torproject.torbrowser-launcher --help https://example.org" ]] || die "run must pass its arguments to the launcher, but flatpak got: ${argv[*]}"
log "ok: run hands its arguments to the launcher"

# The launcher ends right after it has started Tor Browser, so tor stays up for as long as `flatpak ps` lists the app: the tool asks again
# until it lists nothing (here two listings of an instance whose process is gone, which counts as ended).
: >"$FAKE_PS_LOG"
bash "$tool" run || die "run failed while the stand-in for flatpak lists no instance"
[[ "$(wc -l <"$FAKE_PS_LOG")" -eq 1 ]] || die "run must ask flatpak ps once when no instance is left, but it asked $(wc -l <"$FAKE_PS_LOG") times"
echo 2 >"$FAKE_PS_COUNT"
: >"$FAKE_PS_LOG"
bash "$tool" run || die "run failed while the stand-in for flatpak lists instances"
[[ "$(wc -l <"$FAKE_PS_LOG")" -eq 3 ]] || die "run must ask flatpak ps until no instance is left (3 asks), but it asked $(wc -l <"$FAKE_PS_LOG") times"
log "ok: run waits until no instance of the app is left"

# tor says it is ready a second before its socket exists: the tool waits for the socket (the stand-in for inotifywait makes it when it is
# asked to wait, as tor does), and gives up with the reason when it never comes or when inotifywait itself fails.
rm -f "$work/socks"
write_inotifywait() { printf '#!/usr/bin/env bash\n%s\n' "$1" >"$work/bin/inotifywait"; chmod +x "$work/bin/inotifywait"; }
export FAKE_SOCKET="$work/socks"
write_inotifywait 'python3 -I -c "import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$FAKE_SOCKET"'
bash "$tool" run --help >/dev/null || die "run must wait for the socket that tor makes after it said it is ready"
[[ -S "$work/socks" ]] || die "the stand-in for inotifywait was not asked to wait"
log "ok: run waits for the socket of tor"

rm -f "$work/socks"
write_inotifywait 'exit 2'
sed -i 's/^SOCKET_WAIT_SEC=.*/SOCKET_WAIT_SEC=0/' "$tool"
if bash "$tool" run --help 2>"$work/stderr"; then die "run must fail when tor makes no socket"; fi
grep -q 'made no socket' "$work/stderr" || die "run did not say that tor made no socket: $(cat "$work/stderr")"
write_inotifywait 'exit 1'
sed -i 's/^SOCKET_WAIT_SEC=.*/SOCKET_WAIT_SEC=30/' "$tool"
if bash "$tool" run --help 2>"$work/stderr"; then die "run must fail when inotifywait fails"; fi
grep -q 'inotifywait on .* failed with status 1' "$work/stderr" || die "run did not say that inotifywait failed: $(cat "$work/stderr")"
log "ok: run fails with the reason when the socket never comes or the wait itself fails"
python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$work/socks"

printf '%s' "$script" >"$work/install.py"
python3 -P - "$work/install.py" "$address" <<'PY' || die "the program of the install run does not relay the launcher's download to tor, or starts what it must not"
"""Runs the install program against a stand-in for torbrowser_launcher and a stand-in for the unix socket of tor."""

import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading

script = pathlib.Path(sys.argv[1]).read_text()
work = pathlib.Path(tempfile.mkdtemp())

package = work / "modules" / "torbrowser_launcher"
package.mkdir(parents=True)
(package / "launcher.py").write_text(
    """
import os


class Launcher:
    # The unpatched tasks: each one starts a browser, or a new launcher process that would.
    def run(self):
        open(os.environ["FAKE_OUT"] + ".started", "a").write("run ")

    def try_tor(self):
        open(os.environ["FAKE_OUT"] + ".started", "a").write("try_tor ")

    def try_default_mirror(self):
        open(os.environ["FAKE_OUT"] + ".started", "a").write("try_default_mirror ")
"""
)
(package / "__init__.py").write_text(
    """
import os
import socket
import sys

from torbrowser_launcher import launcher


class Window:
    def close(self):
        open(os.environ["FAKE_OUT"] + ".closed", "a").write("closed ")


def main():
    assert sys.argv == sys.argv[:1], "the launcher must not see the address: " + repr(sys.argv)
    if os.environ["FAKE_MODE"] == "end-early":
        return
    # The download: a request to the proxy the settings name, answered by tor.
    with socket.create_connection((os.environ["FAKE_HOST"], int(os.environ["FAKE_PORT"]))) as proxy:
        proxy.sendall(b"ping")
        proxy.shutdown(socket.SHUT_WR)
        reply = b""
        while chunk := proxy.recv(100):
            reply += chunk
    open(os.environ["FAKE_OUT"], "wb").write(reply)
    # The tasks that follow the download, and the two error dialogs that relaunch the launcher.
    for task in ("run", "try_tor", "try_default_mirror"):
        getattr(launcher.Launcher, task)(Window())
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

host = sys.argv[2].rpartition(":")[0]
# The program listens on a free port instead of the one of the settings, so that a service on this machine is not in the way.
probe = socket.socket()
probe.bind((host, 0))
port = probe.getsockname()[1]
probe.close()


def run(mode):
    env = dict(
        os.environ,
        PYTHONPATH=str(work / "modules"),
        TOR_SOCKS_IPC_PATH=str(tor_path),
        FAKE_HOST=host,
        FAKE_PORT=str(port),
        FAKE_OUT=str(work / "out"),
        FAKE_MODE=mode,
        XDG_DATA_HOME=str(work / "data"),
        FAKE_GPGCONF_LOG=str(work / "gpgconf.log"),
    )
    return subprocess.run(
        [sys.executable, "-P", "-c", script, f"{host}:{port}"], env=env, capture_output=True, text=True, timeout=30
    )


bin_dir = work / "bin"
bin_dir.mkdir()
(bin_dir / "gpgconf").write_text('#!/bin/sh\necho "$@" >> "$FAKE_GPGCONF_LOG"\n')
(bin_dir / "gpgconf").chmod(0o755)
os.environ["PATH"] = f"{bin_dir}:{os.environ['PATH']}"

finished = run("download")
assert finished.returncode == 0, f"the install program failed: {finished.stderr}"
assert (work / "out").read_bytes() == b"answer to ping", "the proxy must hand the connection to tor"
expected_stop = f"--homedir {work / 'data' / 'torbrowser' / 'gnupg_homedir'} --kill all\n"
assert (work / "gpgconf.log").read_text() == expected_stop, "the install must stop the gpg agent of the launcher: " + (work / "gpgconf.log").read_text()
assert not (work / "out.started").exists(), "Tor Browser or a new launcher started: " + (work / "out.started").read_text()
assert (work / "out.closed").read_text() == "closed " * 3, "the window must close instead of each of the three tasks"

early = run("end-early")
assert early.returncode != 0 and "before Tor Browser was installed" in early.stderr, (
    f"an install that ends without reaching the end must fail, got {early.returncode}: {early.stderr}"
)
PY
log "ok: the install program relays the download to tor, and starts no browser and no new launcher"
