#!/usr/bin/env python3
import argparse
import json
import os
import select
import socket
import struct
import sys

QMP_ABS_MAX = 32767
GREETING_TIMEOUT_SEC = 30
COMMAND_TIMEOUT_SEC = 30

KEY_ALIASES = {
    "enter": "ret",
    "return": "ret",
    "space": "spc",
    "escape": "esc",
    "del": "delete",
    "win": "meta_l",
    "super": "meta_l",
    "-": "minus",
    "=": "equal",
}

UNSHIFTED_PUNCTUATION = {
    " ": "spc",
    "\t": "tab",
    "\n": "ret",
    "-": "minus",
    "=": "equal",
    "[": "bracket_left",
    "]": "bracket_right",
    ";": "semicolon",
    "'": "apostrophe",
    ",": "comma",
    ".": "dot",
    "/": "slash",
    "\\": "backslash",
    "`": "grave_accent",
}

SHIFTED_PUNCTUATION = {
    "!": "1",
    "@": "2",
    "#": "3",
    "$": "4",
    "%": "5",
    "^": "6",
    "&": "7",
    "*": "8",
    "(": "9",
    ")": "0",
    "_": "minus",
    "+": "equal",
    "{": "bracket_left",
    "}": "bracket_right",
    ":": "semicolon",
    '"': "apostrophe",
    "<": "comma",
    ">": "dot",
    "?": "slash",
    "|": "backslash",
    "~": "grave_accent",
}


class QmpError(Exception):
    pass


class QmpConnection:
    def __init__(self, sock_path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(GREETING_TIMEOUT_SEC)
        try:
            self.sock.connect(sock_path)
        except OSError as err:
            raise QmpError(f"cannot connect to {sock_path}: {err}") from err
        self.reader = self.sock.makefile("r", encoding="utf-8", newline="\n")
        greeting = self._read_message()
        if "QMP" not in greeting:
            raise QmpError(f"unexpected QMP greeting: {greeting}")
        self.sock.settimeout(COMMAND_TIMEOUT_SEC)

    def _read_message(self):
        try:
            line = self.reader.readline()
        except TimeoutError as err:
            raise QmpError("timed out waiting for QEMU to answer on the QMP socket") from err
        if not line:
            raise QmpError("QMP connection closed by QEMU")
        return json.loads(line)

    def negotiate(self):
        self.execute("qmp_capabilities")

    def execute(self, command, arguments=None):
        request = {"execute": command}
        if arguments is not None:
            request["arguments"] = arguments
        self.sock.sendall((json.dumps(request) + "\n").encode("utf-8"))
        while True:
            message = self._read_message()
            if "event" in message:
                continue
            if "error" in message:
                raise QmpError(f"{command}: {message['error'].get('desc', message['error'])}")
            return message.get("return")

    def close(self):
        self.reader.close()
        self.sock.close()


def connect_negotiated(sock_path):
    connection = QmpConnection(sock_path)
    connection.negotiate()
    return connection


def resolve_qcode(token):
    return KEY_ALIASES.get(token, token)


def parse_chord(chord):
    if chord in KEY_ALIASES:
        return [KEY_ALIASES[chord]]
    return [resolve_qcode(token) for token in chord.split("-")]


def qcodes_for_char(char):
    if char in UNSHIFTED_PUNCTUATION:
        return [UNSHIFTED_PUNCTUATION[char]]
    if char in SHIFTED_PUNCTUATION:
        return ["shift", SHIFTED_PUNCTUATION[char]]
    if char.isascii() and char.isdigit():
        return [char]
    if char.isascii() and char.islower():
        return [char]
    if char.isascii() and char.isupper():
        return ["shift", char.lower()]
    raise QmpError(f"no keycode mapping for character {char!r} (U+{ord(char):04X})")


def send_key(connection, qcodes):
    keys = [{"type": "qcode", "data": qcode} for qcode in qcodes]
    connection.execute("send-key", {"keys": keys})


def png_size(path):
    with open(path, "rb") as image:
        header = image.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise QmpError(f"{path} is not a PNG file")
    return struct.unpack(">II", header[16:24])


def screendump(connection, destination):
    connection.execute("screendump", {"filename": destination, "format": "png"})


def command_greeting(args):
    QmpConnection(args.sock).close()


def command_key(args):
    chords = [parse_chord(chord) for chord in args.keys]
    connection = connect_negotiated(args.sock)
    for qcodes in chords:
        send_key(connection, qcodes)
    connection.close()


def command_type(args):
    sequence = [(char, qcodes_for_char(char)) for char in args.text]
    if args.enter:
        sequence.append(("\n", qcodes_for_char("\n")))
    if args.print_keys:
        for char, qcodes in sequence:
            print(f"{char!r}\t{'-'.join(qcodes)}")
        return
    connection = connect_negotiated(args.sock)
    for _, qcodes in sequence:
        send_key(connection, qcodes)
    connection.close()


def command_shot(args):
    if not os.path.isabs(args.output):
        raise QmpError(f"output path must be absolute: {args.output}")
    partial = args.output + ".tmp"
    connection = connect_negotiated(args.sock)
    screendump(connection, partial)
    connection.close()
    os.rename(partial, args.output)
    print(args.output)


def scale_to_abs(pixel, size, axis):
    if not 0 <= pixel < size:
        raise QmpError(f"{axis}={pixel} is outside the {size}px screen")
    return round(pixel * QMP_ABS_MAX / (size - 1)) if size > 1 else 0


def abs_axis_event(axis, value):
    return {"type": "abs", "data": {"axis": axis, "value": value}}


def button_event(button, down):
    return {"type": "btn", "data": {"down": down, "button": button}}


def command_click(args):
    probe = os.path.join(os.path.dirname(os.path.abspath(args.sock)), "click-probe.png")
    connection = connect_negotiated(args.sock)
    screendump(connection, probe)
    try:
        width, height = png_size(probe)
    finally:
        os.unlink(probe)
    move = [
        abs_axis_event("x", scale_to_abs(args.x, width, "x")),
        abs_axis_event("y", scale_to_abs(args.y, height, "y")),
    ]
    connection.execute("input-send-event", {"events": move})
    for _ in range(2 if args.double else 1):
        connection.execute("input-send-event", {"events": [button_event(args.button, True)]})
        connection.execute("input-send-event", {"events": [button_event(args.button, False)]})
    connection.close()


def command_wait_pid(args):
    try:
        pidfd = os.pidfd_open(args.pid)
    except ProcessLookupError:
        return
    except OSError as err:
        raise QmpError(f"cannot watch pid {args.pid}: {err}") from err
    try:
        ready, _, _ = select.select([pidfd], [], [], args.timeout)
    finally:
        os.close(pidfd)
    if not ready:
        raise QmpError(f"pid {args.pid} still running after {args.timeout}s")


def build_parser():
    parser = argparse.ArgumentParser(description="Minimal QMP client for headless QEMU VMs")
    parser.add_argument("--sock")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("greeting").set_defaults(run=command_greeting)

    key = commands.add_parser("key")
    key.add_argument("keys", nargs="+")
    key.set_defaults(run=command_key)

    typing = commands.add_parser("type")
    typing.add_argument("--enter", action="store_true")
    typing.add_argument("--print-keys", action="store_true")
    typing.add_argument("text")
    typing.set_defaults(run=command_type)

    shot = commands.add_parser("shot")
    shot.add_argument("output")
    shot.set_defaults(run=command_shot)

    click = commands.add_parser("click")
    click.add_argument("x", type=int)
    click.add_argument("y", type=int)
    click.add_argument("--button", choices=["left", "right", "middle"], default="left")
    click.add_argument("--double", action="store_true")
    click.set_defaults(run=command_click)

    wait_pid = commands.add_parser("wait-pid")
    wait_pid.add_argument("pid", type=int)
    wait_pid.add_argument("--timeout", type=float, default=None)
    wait_pid.set_defaults(run=command_wait_pid)
    return parser


def main():
    args = build_parser().parse_args()
    needs_sock = args.command != "wait-pid" and not (args.command == "type" and args.print_keys)
    if needs_sock and args.sock is None:
        print("qmp.py: --sock is required", file=sys.stderr)
        return 2
    try:
        args.run(args)
    except QmpError as err:
        print(f"qmp.py: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
