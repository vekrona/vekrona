"""Sends one DNS query over UDP to the address given and exits 0 when the attempt fails within a second for any reason but a
timeout (the kill switch rejects it), 1 when something answered, 2 when it ran into the timeout, 3 when it failed too slowly."""
import socket
import sys
import time

QUERY = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
FAST_SEC = 1
TIMEOUT_SEC = 3

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(TIMEOUT_SEC)
started = time.monotonic()
try:
    sock.connect((sys.argv[1], 53))
    sock.send(QUERY)
    sock.recv(512)
except socket.timeout:
    print("no answer, no rejection: the packets were dropped")
    sys.exit(2)
except OSError as exc:
    elapsed = time.monotonic() - started
    print("rejected after %.2f s: %s" % (elapsed, exc.strerror))
    sys.exit(0 if elapsed < FAST_SEC else 3)
print("the resolver answered")
sys.exit(1)
