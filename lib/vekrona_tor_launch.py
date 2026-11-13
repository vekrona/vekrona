"""The program of `vekrona-tor-browser run`, run as `python3 -P -c <this file> HOST:PORT ARGS...` inside the Tor Browser Launcher's sandbox.

That sandbox has no network, only its own loopback. The launcher downloads through the SOCKS proxy that settings.json names (it
cannot use a unix socket), so this program listens on HOST:PORT of that loopback and hands every connection to the unix socket of
the system tor (TOR_SOCKS_IPC_PATH, set by the Flatpak override). Nothing listens on the host.

Apart from that the launcher runs as it does for a person: it downloads and checks Tor Browser when it is missing or too old, and
then starts it, and it ends when Tor Browser has ended. ARGS are the launcher's own arguments. Two of its paths are replaced. Its two
error dialogs relaunch it by running sys.argv[0], which is "-c" here, so they can only close the window. The launcher's gpg agent
outlives it and keeps the sandbox alive: vekrona-tor-browser ends that agent from the host, which sees every way this program can end.
"""

import errno
import os
import socket
import sys
import threading

import torbrowser_launcher
from torbrowser_launcher import launcher

CHUNK_BYTES = 65536

host, _, port = sys.argv[1].rpartition(":")
# The launcher parses sys.argv itself: what remains is what `run` was given.
sys.argv = [sys.argv[0], *sys.argv[2:]]
tor_socket_path = os.environ["TOR_SOCKS_IPC_PATH"]


def pump(source, sink):
    """Copies source to sink until source ends, then tells sink that no more comes. A reset by either side ends the copy the same
    way: the launcher resets a connection when it is done with it, and the other side must learn of it too."""
    try:
        while data := source.recv(CHUNK_BYTES):
            sink.sendall(data)
    except (ConnectionResetError, BrokenPipeError):
        pass
    try:
        sink.shutdown(socket.SHUT_WR)
    except OSError as error:
        # The sink was reset as well, so it has nothing left to be told.
        if error.errno != errno.ENOTCONN:
            raise


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


def close_instead_of_relaunch(window):
    window.close()


listener = socket.create_server((host, int(port)))
threading.Thread(target=serve, args=(listener,), daemon=True).start()

launcher.Launcher.try_default_mirror = close_instead_of_relaunch
launcher.Launcher.try_tor = close_instead_of_relaunch
torbrowser_launcher.main()
