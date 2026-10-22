import os
import shutil
import subprocess
import tempfile
import unittest

from update_harness import REPO, write_executable

FAKE_SYSTEMCTL = """#!/bin/sh
printf '%s\\n' "systemctl $*" >> "$FAKE_LOG"
if [ -n "$FAKE_SYSTEMCTL_ERROR" ]; then echo "$FAKE_SYSTEMCTL_ERROR" >&2; exit 1; fi
"""

FAKE_REPORTER = """#!/bin/sh
printf '%s\\n' "$*" >> "$FAKE_LOG"
exit "${FAKE_REPORT_STATUS:-0}"
"""

FAKE_NOTIFY_SEND = """#!/bin/sh
printf '%s\\n' "notify-send $*" >> "$FAKE_LOG"
exit "${FAKE_NOTIFY_STATUS:-0}"
"""


class UpdateStartTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vekrona-update-start-test-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        write_executable(os.path.join(self.root, "systemctl"), FAKE_SYSTEMCTL)
        write_executable(os.path.join(self.root, "notify-send"), FAKE_NOTIFY_SEND)
        write_executable(os.path.join(self.root, "reporter"), FAKE_REPORTER)
        self.log = os.path.join(self.root, "calls.log")
        open(self.log, "w").close()

    def start(self, *args, **env):
        return subprocess.run(
            [os.path.join(REPO, "bin", "vekrona-update-start"), *args],
            env={"PATH": f"{self.root}:/usr/bin:/bin", "HOME": self.root,
                 "VEKRONA_ERROR_REPORTER": os.path.join(self.root, "reporter"),
                 "FAKE_LOG": self.log, "FAKE_SYSTEMCTL_ERROR": "", **env},
            capture_output=True, text=True, timeout=60)

    def calls(self):
        with open(self.log) as f:
            return f.read().splitlines()

    def test_the_unit_is_started_without_waiting_for_it(self):
        result = self.start("vekrona-update-reboot.service")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(self.calls(), ["systemctl start --no-block vekrona-update-reboot.service"])

    def test_a_refusal_is_reported_once_and_fails(self):
        result = self.start("vekrona-update-reboot.service",
                            FAKE_SYSTEMCTL_ERROR="Interactive authentication required.")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Interactive authentication required.", result.stderr)
        self.assertEqual(self.calls()[1:], [
            "report --title vekrona update: systemctl start vekrona-update-reboot.service failed: "
            "Interactive authentication required. --source vekrona"])

    def test_a_refusal_that_cannot_be_reported_is_toasted_instead(self):
        result = self.start("vekrona-update-reboot.service", FAKE_SYSTEMCTL_ERROR="denied", FAKE_REPORT_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to report this error", result.stderr)
        report, notification = self.calls()[1:]
        self.assertTrue(report.startswith("report --title "), report)
        self.assertTrue(notification.startswith("notify-send -u critical -a vekrona -- "), notification)
        self.assertIn("denied", notification)

    def test_a_refusal_is_still_an_error_when_it_can_neither_be_reported_nor_toasted(self):
        result = self.start("vekrona-update-reboot.service", FAKE_SYSTEMCTL_ERROR="denied",
                            FAKE_REPORT_STATUS="1", FAKE_NOTIFY_STATUS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to show this error as a notification", result.stderr)

    def test_only_vekrona_update_units_can_be_started(self):
        for args in ([], ["vekrona-update-reboot.service", "extra"], ["sshd.service"], ["vekrona-update-x"],
                     ["vekrona-update-x.timer"], [""]):
            with self.subTest(args):
                self.assertEqual(self.start(*args).returncode, 2)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
