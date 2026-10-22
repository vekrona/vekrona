import json
import os
import selectors
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "tests", "errors"))
from harness import SessionBus, write_executable  # noqa: E402

EVENT_DEADLINE_SEC = 30

FAKE_NOTIFY_SEND = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_LOG"
"""


def read_line(stream, deadline=EVENT_DEADLINE_SEC):
    selector = selectors.DefaultSelector()
    selector.register(stream, selectors.EVENT_READ)
    try:
        if not selector.select(timeout=deadline):
            raise AssertionError(f"nothing to read within {deadline}s")
    finally:
        selector.close()
    return stream.readline()


class FakeDaemon:
    """The fake notification daemon (fake_notification_daemon.py) on a private session bus."""

    def __init__(self, bus_address):
        self.process = subprocess.Popen(
            [sys.executable, "-B", "-W", "ignore::DeprecationWarning",
             os.path.join(HERE, "fake_notification_daemon.py")],
            env={**os.environ, "DBUS_SESSION_BUS_ADDRESS": bus_address, "PYTHONDONTWRITEBYTECODE": "1"},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.expect("ready")

    def event(self):
        return json.loads(read_line(self.process.stdout))

    def expect(self, name):
        event = self.event()
        assert event["event"] == name, f"expected a {name} event, got {event}"
        return event

    def command(self, text):
        self.process.stdin.write(text + "\n")
        self.process.stdin.flush()
        done = self.expect("done")
        assert done["command"] == text.split()[0], done

    def close(self):
        self.process.stdin.close()
        self.process.wait()
        self.process.stdout.close()


class UpdateAskTestCase(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.bus = SessionBus()
        cls.addClassCleanup(cls.bus.close)

    def setUp(self):
        self.fakes = tempfile.TemporaryDirectory(prefix="vekrona-update-test-")
        self.addCleanup(self.fakes.cleanup)
        self.notify_send_log = os.path.join(self.fakes.name, "notify-send.log")
        open(self.notify_send_log, "w").close()
        write_executable(os.path.join(self.fakes.name, "notify-send"), FAKE_NOTIFY_SEND)
        self.env = {
            "PATH": f"{self.fakes.name}:/usr/bin:/bin",
            "HOME": self.fakes.name,
            "DBUS_SESSION_BUS_ADDRESS": self.bus.address,
            "FAKE_LOG": self.notify_send_log,
            "PYTHONDONTWRITEBYTECODE": "1",
        }

    def start_daemon(self):
        daemon = FakeDaemon(self.bus.address)
        self.addCleanup(daemon.close)
        return daemon

    def start_ask(self, *args):
        process = subprocess.Popen(
            [sys.executable, "-B", os.path.join(REPO, "bin", "vekrona-update-ask"), *args],
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, process)
        return process

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.communicate()

    def finish(self, process):
        stdout, stderr = process.communicate(timeout=EVENT_DEADLINE_SEC)
        return process.returncode, stdout, stderr

    def run_ask(self, *args):
        return self.finish(self.start_ask(*args))
