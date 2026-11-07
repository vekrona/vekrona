"""The program of `vekrona-tor-browser install`, run as `python3 -P -c <this file> HOST:PORT` inside the Tor Browser Launcher's sandbox.

That sandbox has no network, only its own loopback. The launcher downloads through the SOCKS proxy that settings.json names (it
cannot use a unix socket), so this program listens on HOST:PORT of that loopback and hands every connection to the unix socket of
the system tor (TOR_SOCKS_IPC_PATH, set by the Flatpak override). Nothing listens on the host.

The launcher's last task, "run", starts Tor Browser in the sandbox it runs in, and it has no flag to skip that. The download, the
signature check and the extraction before it are the launcher's own; this program replaces "run" with "close the window", and fails
when the launcher ends without having reached it. The two error dialogs that relaunch the launcher in a new process (a try of the
default mirror, a try over tor) are replaced the same way: the new process would run the unpatched "run". The launcher checks the
signature with gpg, which leaves its agent running in the sandbox, and the sandbox lives as long as the agent does: the program
stops the agent before it ends.
"""

import os
import socket
import subprocess
import sys
import threading

import torbrowser_launcher
from torbrowser_launcher import launcher

CHUNK_BYTES = 65536

host, _, port = sys.argv[1].rpartition(":")
# The launcher parses sys.argv itself.
sys.argv = sys.argv[:1]
tor_socket_path = os.environ["TOR_SOCKS_IPC_PATH"]


def pump(source, sink):
    """Copies source to sink until source ends, then tells sink that no more comes."""
    while data := source.recv(CHUNK_BYTES):
        sink.sendall(data)
    sink.shutdown(socket.SHUT_WR)


def relay(client):
    with client, socket.socket(socket.AF_UNIX) as tor:
        tor.connect(tor_socket_path)
        upstream = threading.Thread(target=pump, args=(client, tor), daemon=True)
        upstream.start()
        pump(tor, client)
        upstream.join()


def serve(listener):
    while True:
        client, _ = listener.accept()
        threading.Thread(target=relay, args=(client,), daemon=True).start()


reached = []


def finish_instead_of_run(window):
    reached.append(True)
    window.close()


def close_instead_of_relaunch(window):
    window.close()


listener = socket.create_server((host, int(port)))
threading.Thread(target=serve, args=(listener,), daemon=True).start()

launcher.Launcher.run = finish_instead_of_run
launcher.Launcher.try_default_mirror = close_instead_of_relaunch
launcher.Launcher.try_tor = close_instead_of_relaunch
try:
    torbrowser_launcher.main()
except SystemExit:
    pass
finally:
    # The launcher's GnuPG home: $XDG_DATA_HOME/torbrowser/gnupg_homedir (the Flatpak sets XDG_DATA_HOME).
    gnupg_home = os.path.join(os.environ["XDG_DATA_HOME"], "torbrowser", "gnupg_homedir")
    subprocess.run(["gpgconf", "--homedir", gnupg_home, "--kill", "all"], check=True)
sys.exit(0 if reached else "the launcher ended before Tor Browser was installed")
