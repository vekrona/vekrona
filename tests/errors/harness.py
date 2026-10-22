import errno
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))
HERE = os.path.dirname(os.path.realpath(__file__))

sys.path.insert(0, os.path.join(REPO, "tests"))
from require_vm import require_vm  # noqa: E402

require_vm()

SYSTEMD_EXE = "/usr/lib/systemd/systemd"
COREDUMP_EXE = "/usr/lib/systemd/systemd-coredump"
OOMD_EXE = "/usr/lib/systemd/systemd-oomd"
MESSAGE_ID_UNIT_FAILED = "d9b373ed55a64feb8242e02dbe79a49c"
MESSAGE_ID_UNIT_PROCESS_EXITED = "98e322203f7a4ed290d09fe03c09fe15"
MESSAGE_ID_COREDUMP = "fc2e22bc6ee647b6b90729ab34a250b1"
MESSAGE_ID_KERNEL_OOM = "fe6faa94e7774663a0da52717891d8ef"
MESSAGE_ID_OOMD_KILL = "d989611b15e44c9dbf31e3c81256e4ed"

FAKE_JOURNALCTL = """#!/bin/sh
printf 'journalctl %s\\n' "$*" >> "$FAKE_LOG"
for arg; do
  if [ "$arg" = "-f" ]; then exec cat "$FAKE_JOURNAL"; fi
done
"""

FAKE_LOGGING_TOOL = """#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
"""

FAKE_SYSTEMCTL = """#!/bin/sh
printf 'systemctl %s\\n' "$*" >> "$FAKE_LOG"
if [ -n "$FAKE_RELEASE" ]; then cat "$FAKE_RELEASE" > /dev/null; fi
"""

FAKE_NOTIFY_SEND = """#!/bin/sh
printf 'notify-send %s\\n' "$*" >> "$FAKE_LOG"
if [ "${FAKE_NOTIFY_STATUS:-0}" != 0 ]; then echo "no notification daemon" >&2; fi
exit "${FAKE_NOTIFY_STATUS:-0}"
"""


def write_executable(path, text):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, 0o755)


def journal_entry(**fields):
    entry = {"PRIORITY": "3", "SYSLOG_IDENTIFIER": "test", "MESSAGE": "test message"}
    entry.update(fields)
    return entry


def report_entry(title, summary="", source="manual"):
    fields = {
        "SYSLOG_IDENTIFIER": "vekrona", "PRIORITY": "3", "VEKRONA_SOURCE": source,
        "VEKRONA_TITLE": title, "MESSAGE": f"{title}: {summary}" if summary else title,
        "_PID": "4242", "_UID": str(os.getuid()), "_EXE": "/usr/bin/python3",
    }
    if summary:
        fields["VEKRONA_SUMMARY"] = summary
    return fields


def system_unit_failed_entry(unit, result="exit-code"):
    return {
        "MESSAGE_ID": MESSAGE_ID_UNIT_FAILED, "PRIORITY": "4", "UNIT": unit, "UNIT_RESULT": result,
        "MESSAGE": f"{unit}: Failed with result '{result}'.", "SYSLOG_IDENTIFIER": "systemd",
        "_PID": "1", "_UID": "0", "_EXE": SYSTEMD_EXE, "_COMM": "systemd", "_SYSTEMD_UNIT": "init.scope",
    }


def user_manager_fields():
    uid = str(os.getuid())
    return {
        "_PID": "2121", "_UID": uid, "_EXE": SYSTEMD_EXE, "_COMM": "systemd",
        "_SYSTEMD_UNIT": f"user@{uid}.service", "SYSLOG_IDENTIFIER": "systemd",
    }


def user_unit_failed_entry(unit, result="exit-code"):
    return {
        "MESSAGE_ID": MESSAGE_ID_UNIT_FAILED, "PRIORITY": "4", "USER_UNIT": unit, "UNIT_RESULT": result,
        "MESSAGE": f"{unit}: Failed with result '{result}'.", **user_manager_fields(),
    }


def user_unit_exited_entry(unit, code, status):
    return {
        "MESSAGE_ID": MESSAGE_ID_UNIT_PROCESS_EXITED, "PRIORITY": "5", "USER_UNIT": unit,
        "EXIT_CODE": code, "EXIT_STATUS": status,
        "MESSAGE": f"{unit}: Main process exited, code={code}, status={status}/X",
        **user_manager_fields(),
    }


def coredump_entry(pid, exe="/usr/bin/crasher", comm="crasher", signal_name="SIGSEGV", **overrides):
    entry = {
        "MESSAGE_ID": MESSAGE_ID_COREDUMP, "PRIORITY": "2", "COREDUMP_PID": pid, "COREDUMP_EXE": exe,
        "COREDUMP_COMM": comm, "COREDUMP_SIGNAL_NAME": signal_name, "MESSAGE": "dumped core",
        "SYSLOG_IDENTIFIER": "systemd-coredump", "_PID": "5000", "_UID": str(os.getuid()),
        "_EXE": COREDUMP_EXE, "_COMM": "systemd-coredum",
        "_SYSTEMD_UNIT": "systemd-coredump@0-1-2.service",
    }
    entry.update(overrides)
    return entry


class SessionBus:
    def __init__(self):
        self.daemon = subprocess.Popen(
            ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
            stdout=subprocess.PIPE, text=True)
        self.address = self.daemon.stdout.readline().strip()
        if not self.address:
            raise RuntimeError("dbus-daemon did not print a bus address")

    def close(self):
        self.daemon.terminate()
        self.daemon.wait()
        self.daemon.stdout.close()


class Sandbox:
    def __init__(self, bus_address):
        self.root = tempfile.mkdtemp(prefix="vekrona-error-test-")
        self.bin = os.path.join(self.root, "bin")
        self.lib = os.path.join(self.root, "lib")
        self.fakes = os.path.join(self.root, "fakes")
        for d in (self.bin, self.lib, self.fakes):
            os.makedirs(d)
        shutil.copy(os.path.join(REPO, "bin", "vekrona-error"), self.bin)
        shutil.copy(os.path.join(REPO, "lib", "vekrona_cli.py"), self.lib)
        self.tool = os.path.join(self.bin, "vekrona-error")
        write_executable(os.path.join(self.fakes, "journalctl"), FAKE_JOURNALCTL)
        write_executable(os.path.join(self.fakes, "systemctl"), FAKE_SYSTEMCTL)
        write_executable(os.path.join(self.fakes, "notify-send"), FAKE_NOTIFY_SEND)
        write_executable(os.path.join(self.fakes, "coredumpctl"), FAKE_LOGGING_TOOL)
        self.log = os.path.join(self.root, "calls.log")
        self.journal = os.path.join(self.root, "journal.jsonl")
        self.notifications = os.path.join(self.root, "notifications.jsonl")
        for path in (self.log, self.journal, self.notifications):
            open(path, "w").close()
        self.default_mutes_dir = os.path.join(self.root, "errors-mute.d")
        self.env = {
            "VEKRONA_ERRORS_MUTE_DIR": self.default_mutes_dir,
            "PATH": f"{self.fakes}:/usr/bin:/bin",
            "HOME": os.path.join(self.root, "home"),
            "XDG_STATE_HOME": os.path.join(self.root, "state"),
            "XDG_CONFIG_HOME": os.path.join(self.root, "config"),
            "DBUS_SESSION_BUS_ADDRESS": bus_address,
            "FAKE_LOG": self.log,
            "FAKE_JOURNAL": self.journal,
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self.watchers = []
        self.release = None
        self.notification_server = subprocess.Popen(
            [sys.executable, "-B", "-W", "ignore::DeprecationWarning", os.path.join(HERE, "fake_notifications.py"), self.notifications],
            env=self.env, stdout=subprocess.PIPE, text=True)
        if self.notification_server.stdout.readline().strip() != "ready":
            self.close()
            raise RuntimeError("the fake notification server did not start")

    def close(self):
        for watcher in self.watchers:
            watcher.kill()
            watcher.communicate()
        self.release_blocked_context_captures()
        self.notification_server.terminate()
        self.notification_server.wait()
        self.notification_server.stdout.close()
        shutil.rmtree(self.root, ignore_errors=True)

    # The fake systemctl that captures an error's context blocks on this FIFO until the test writes to it, which lets a test hold
    # the capture of one error while the watcher goes on with the next. Returns the environment that makes the watcher's fake
    # systemctl block.
    def hold_context_captures(self):
        self.release = os.path.join(self.root, "release")
        os.mkfifo(self.release)
        return {"FAKE_RELEASE": self.release}

    def release_context_captures(self):
        with open(self.release, "w") as fifo:
            fifo.write("go")

    # A test that fails while a capture is held leaves its fake systemctl blocked on the FIFO, orphaned once the watcher is killed.
    # Opening the write end frees every reader; with none blocked there is no reader, and the open fails at once.
    def release_blocked_context_captures(self):
        if self.release is None:
            return
        try:
            os.close(os.open(self.release, os.O_WRONLY | os.O_NONBLOCK))
        except OSError as err:
            if err.errno != errno.ENXIO:
                raise

    def run(self, *args, extra_env=None, timeout=60, just_booted=False):
        env = {**self.env, **(extra_env or {})}
        command = [sys.executable, "-B", self.tool, *args]
        if just_booted:
            with open("/proc/uptime") as f:
                uptime = int(float(f.read().split()[0]))
            command = ["unshare", "--user", "--map-current-user", "--time",
                       "--monotonic", str(1 - uptime), *command]
        return subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)

    def install_default_mutes(self, text, name="10-test.conf"):
        os.makedirs(self.default_mutes_dir, exist_ok=True)
        with open(os.path.join(self.default_mutes_dir, name), "w") as f:
            f.write(text)

    def write_journal(self, entries):
        with open(self.journal, "w") as f:
            for entry in entries:
                f.write((entry if isinstance(entry, str) else json.dumps(entry)) + "\n")

    def watch(self, entries, just_booted=False):
        self.write_journal(entries)
        return self.run("watch", just_booted=just_booted)

    def start_watch(self, entries, extra_env=None):
        self.write_journal(entries)
        proc = subprocess.Popen([sys.executable, "-B", self.tool, "watch"],
                                env={**self.env, **(extra_env or {})},
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.watchers.append(proc)
        return proc

    # Runs `list` back to back until the error titled `title` is recorded: the watcher has no signal to wait on.
    def wait_until_listed(self, title, deadline=30):
        end = time.monotonic() + deadline
        while title not in self.run("list").stdout:
            if time.monotonic() > end:
                raise AssertionError(f"{title!r} not recorded within {deadline}s")

    def error_id_titled(self, title):
        (line,) = [row for row in self.run("list", "--all").stdout.splitlines() if title in row]
        return line.split()[0]

    # The store's lock is a file, so a directory in its place makes every write to the store fail.
    def make_the_store_unwritable(self):
        os.makedirs(os.path.join(self.store_dir(), ".lock"))

    def unread_count(self):
        with open(os.path.join(self.store_dir(), "unread")) as f:
            return int(f.read())

    def ingest_report(self, title, summary="", source="manual"):
        self.watch([report_entry(title, summary, source)])
        return self.latest_error_id()

    def latest_error_id(self):
        listing = self.run("list", "--all").stdout.splitlines()[1:]
        return listing[0].split()[0]

    def store_dir(self):
        return os.path.join(self.env["XDG_STATE_HOME"], "vekrona", "errors")

    def external_calls(self):
        with open(self.log) as f:
            return f.read().splitlines()

    def notify_send_calls(self):
        return [call for call in self.external_calls() if call.startswith("notify-send")]

    def sent_notifications(self):
        with open(self.notifications) as f:
            return [json.loads(line) for line in f]

    def toasts_mentioning(self, text):
        return [toast for toast in self.sent_notifications() if text in toast["body"]]


class SandboxTestCase(unittest.TestCase):
    bus = None

    @classmethod
    def setUpClass(cls):
        cls.bus = SessionBus()
        cls.addClassCleanup(cls.bus.close)

    def setUp(self):
        self.sandbox = Sandbox(self.bus.address)
        self.addCleanup(self.sandbox.close)
