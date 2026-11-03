#!/usr/bin/env python3
"""Guest-side relay between the shell and Sway's IPC socket, for tests/e2e/app-switch-reseed.sh.

Usage: sway-ipc-gap-proxy.py LISTEN_PATH STATE_PATH

Listens on LISTEN_PATH and relays every connection to $SWAYSOCK frame by frame, unchanged. STATE_PATH holds one line: the
mode ("relay", "gap" or "hold"), then, counted since the last hold began, the get_tree requests the shell sent during the hold
("asked=N"), the get_tree answers kept back ("held=N") and the window close events passed on ("closes=N").

SIGUSR1 opens a gap: nothing Sway sends reaches the shell any more, so the events of that time are lost. SIGUSR2 closes it
and sends every connection of the shell bytes that are no IPC frame. Quickshell takes that for a fatal IPC error and
recreates the connection, which is the only reconnect it has: its I3.onConnected fires again.

SIGHUP starts a hold: Sway's answers to get_tree are kept back while everything else, events included, passes, so the shell
sees events that are newer than the tree it is still waiting for. SIGALRM ends the hold and passes the kept answers on.
"""
import asyncio
import json
import os
import signal
import struct
import sys

LISTEN_PATH, STATE_PATH = sys.argv[1:]
SWAYSOCK = os.environ["SWAYSOCK"]
MAGIC = b"i3-ipc"
HEADER = struct.Struct("<II")
GET_TREE = 4
WINDOW_EVENT = 0x80000003
# A frame is "i3-ipc", a length and a type; this has no magic.
NOT_A_FRAME = b"garbag" + HEADER.pack(0, 0)

gap = False
hold = False
asked = 0
closes = 0
# (shell writer, frame) of each get_tree answer kept back during a hold, in the order Sway sent them.
held = []
shell_ends = set()


def set_state():
    mode = "gap" if gap else "hold" if hold else "relay"
    with open(STATE_PATH, "w") as f:
        f.write(f"{mode} asked={asked} held={len(held)} closes={closes}\n")


async def read_frame(source):
    """The next IPC frame and its type, or None when the peer closed the connection between frames."""
    try:
        header = await source.readexactly(len(MAGIC) + HEADER.size)
    except asyncio.IncompleteReadError as error:
        if error.partial:
            raise
        return None
    if not header.startswith(MAGIC):
        raise ValueError(f"not an IPC frame: {header!r}")
    length, kind = HEADER.unpack_from(header, len(MAGIC))
    return header + await source.readexactly(length), kind


def is_close_event(frame, kind):
    return kind == WINDOW_EVENT and json.loads(frame[len(MAGIC) + HEADER.size :]).get("change") == "close"


async def pump(source, sink, from_sway):
    global asked, closes
    # A peer that closed ends the connection: only that is swallowed.
    try:
        while read := await read_frame(source):
            frame, kind = read
            if from_sway and gap:
                continue
            if hold and kind == GET_TREE:
                if from_sway:
                    held.append((sink, frame))
                    set_state()
                    continue
                asked += 1
                set_state()
            if from_sway and is_close_event(frame, kind):
                closes += 1
                set_state()
            sink.write(frame)
            await sink.drain()
    except ConnectionError:
        pass
    finally:
        sink.close()


async def relay(shell_reader, shell_writer):
    try:
        sway_reader, sway_writer = await asyncio.open_unix_connection(SWAYSOCK)
    except OSError as error:
        print(f"sway-ipc-gap-proxy: cannot connect to {SWAYSOCK}: {error}", file=sys.stderr)
        shell_writer.close()
        return
    shell_ends.add(shell_writer)
    try:
        await asyncio.gather(
            pump(shell_reader, sway_writer, from_sway=False),
            pump(sway_reader, shell_writer, from_sway=True),
        )
    finally:
        shell_ends.discard(shell_writer)


def open_gap():
    global gap
    gap = True
    set_state()


def close_gap():
    global gap
    for writer in shell_ends:
        writer.write(NOT_A_FRAME)
    gap = False
    set_state()


def start_hold():
    global hold, asked, closes
    hold = True
    asked = 0
    closes = 0
    set_state()


def end_hold():
    global hold
    hold = False
    for writer, frame in held:
        writer.write(frame)
    held.clear()
    set_state()


async def main():
    server = await asyncio.start_unix_server(relay, LISTEN_PATH)
    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGUSR1, open_gap)
    loop.add_signal_handler(signal.SIGUSR2, close_gap)
    loop.add_signal_handler(signal.SIGHUP, start_hold)
    loop.add_signal_handler(signal.SIGALRM, end_hold)
    set_state()
    await server.serve_forever()


asyncio.run(main())
