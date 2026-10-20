import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from update_harness import REPO, write_executable

RECORDING_STUB = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")
"""

FAKE_ASK = RECORDING_STUB + """
sys.stdout.write(os.environ["FAKE_ASK_ANSWER"] + "\\n")
sys.exit(int(os.environ.get("FAKE_ASK_STATUS", "0")))
"""

FAKE_START = RECORDING_STUB + """
sys.exit(int(os.environ.get("FAKE_START_STATUS", "0")))
"""

FAKE_NOTIFY_SEND = RECORDING_STUB

FAKE_ERROR_REPORTER = RECORDING_STUB + """
sys.exit(int(os.environ.get("FAKE_REPORT_STATUS", "0")))
"""

FLATPAK = {"name": "Flatpak", "items": [{"name": "org.signal.Signal", "from": "", "to": ""}]}
SYSTEM = {"name": "System packages", "items": [{"name": "kernel-core", "from": "2.1.0", "to": "2.1.3"},
                                              {"name": "curl", "from": "0.9.1", "to": "0.9.4"}]}


def numbered(count):
    return {"name": "System packages",
            "items": [{"name": f"pkg{n}", "from": f"{n}.0", "to": f"{n}.1"} for n in range(1, count + 1)]}


def state(groups, pending=True, **extra):
    return {"checked": "2026-10-09T09:00:03+02:00", "pending": pending, "night_armed": True,
            "groups": groups, **extra}


class UpdateNotifyTestCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="vekrona-update-notify-test-")
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        bin_dir, lib_dir = os.path.join(self.root, "bin"), os.path.join(self.root, "lib")
        os.makedirs(bin_dir)
        os.makedirs(lib_dir)
        shutil.copy(os.path.join(REPO, "bin", "vekrona-update-notify"), bin_dir)
        shutil.copy(os.path.join(REPO, "lib", "vekrona_cli.py"), lib_dir)
        write_executable(os.path.join(bin_dir, "vekrona-update-ask"), FAKE_ASK)
        write_executable(os.path.join(bin_dir, "vekrona-update-start"), FAKE_START)
        write_executable(os.path.join(bin_dir, "notify-send"), FAKE_NOTIFY_SEND)
        write_executable(os.path.join(bin_dir, "vekrona-error"), FAKE_ERROR_REPORTER)
        self.tool = os.path.join(bin_dir, "vekrona-update-notify")
        self.updates = os.path.join(self.root, "updates.json")
        self.state_home = os.path.join(self.root, "state")
        self.notified = os.path.join(self.state_home, "vekrona", "update-notified")
        self.log = os.path.join(self.root, "calls.log")
        open(self.log, "w").close()

    def write_updates(self, content):
        with open(self.updates, "w") as f:
            f.write(content if isinstance(content, str) else json.dumps(content))

    def run_notify(self, answer="timeout", **extra_env):
        env = {"PATH": f"{os.path.dirname(self.tool)}:/usr/bin:/bin", "HOME": self.root,
               "XDG_STATE_HOME": self.state_home, "VEKRONA_UPDATES_FILE": self.updates,
               "FAKE_LOG": self.log, "FAKE_ASK_ANSWER": answer, "PYTHONDONTWRITEBYTECODE": "1", **extra_env}
        return subprocess.run([sys.executable, "-B", self.tool, "run"], env=env, capture_output=True, text=True,
                              timeout=60)

    def calls(self):
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def asks(self):
        return [call for call in self.calls() if call[0] == "vekrona-update-ask"]

    def ask_args(self):
        (call,) = self.asks()
        args = call[1:]
        return {"timeout": int(args[args.index("--timeout") + 1]), "title": args[args.index("--title") + 1],
                "body": args[args.index("--body") + 1],
                "actions": [args[i + 1] for i, arg in enumerate(args) if arg == "--action"]}

    def body(self, groups):
        self.write_updates(state(groups))
        self.assertEqual(self.run_notify().returncode, 0)
        return self.ask_args()["body"]


class ToastTest(UpdateNotifyTestCase):
    def test_the_toast_offers_install_now_and_not_tonight(self):
        self.write_updates(state([SYSTEM]))
        result = self.run_notify()
        self.assertEqual(result.returncode, 0, result.stderr)
        asked = self.ask_args()
        self.assertEqual(asked["title"], "Updates available")
        self.assertEqual(sorted(asked["actions"]), ["install=Install now", "skip=Not tonight"])

    def test_the_first_action_is_the_harmless_one_because_a_click_on_the_toast_body_runs_it(self):
        self.write_updates(state([SYSTEM]))
        self.assertEqual(self.run_notify().returncode, 0)
        self.assertEqual(self.ask_args()["actions"][0], "skip=Not tonight")

    def test_the_toast_stays_until_midnight_at_the_latest(self):
        self.write_updates(state([SYSTEM]))
        self.run_notify()
        self.assertTrue(1 <= self.ask_args()["timeout"] <= 24 * 60 * 60)

    def test_each_group_is_a_line_with_its_versions(self):
        self.assertEqual(
            self.body([SYSTEM, FLATPAK]),
            "System packages: kernel-core 2.1.0 → 2.1.3, curl 0.9.1 → 0.9.4\nFlatpak: org.signal.Signal")

    def test_an_item_with_only_one_known_version_is_listed_by_name(self):
        group = {"name": "Proton", "items": [{"name": "a", "from": "1", "to": ""}, {"name": "b", "from": "", "to": "2"}]}
        self.assertEqual(self.body([group]), "Proton: a, b")

    def test_five_items_are_all_listed(self):
        self.assertEqual(
            self.body([numbered(5)]),
            "System packages: pkg1 1.0 → 1.1, pkg2 2.0 → 2.1, pkg3 3.0 → 3.1, pkg4 4.0 → 4.1, pkg5 5.0 → 5.1")

    def test_more_than_five_items_show_the_count_and_the_first_five(self):
        self.assertEqual(
            self.body([numbered(6)]),
            "System packages: 6 updates: pkg1 1.0 → 1.1, pkg2 2.0 → 2.1, pkg3 3.0 → 3.1, "
            "pkg4 4.0 → 4.1, pkg5 5.0 → 5.1, …")

    def test_a_group_with_no_items_is_left_out(self):
        self.assertEqual(self.body([{"name": "Proton", "items": []}, FLATPAK]), "Flatpak: org.signal.Signal")


class NothingToTellTest(UpdateNotifyTestCase):
    def assert_silent_success(self):
        result = self.run_notify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), [])
        return result

    def test_a_missing_file_means_the_check_has_not_run_yet(self):
        result = self.assert_silent_success()
        self.assertIn("does not exist yet", result.stderr)

    def test_nothing_pending_is_not_announced(self):
        self.write_updates(state([], pending=False))
        self.assert_silent_success()

    def test_nothing_pending_wins_over_leftover_groups(self):
        self.write_updates(state([SYSTEM], pending=False))
        self.assert_silent_success()

    def test_pending_with_only_empty_groups_is_not_announced(self):
        self.write_updates(state([{"name": "Proton", "items": []}]))
        self.assert_silent_success()


class MalformedFileTest(UpdateNotifyTestCase):
    def test_a_file_that_cannot_be_trusted_fails_loudly_and_asks_nothing(self):
        malformed = {
            "empty": "",
            "not JSON": "lizard",
            "truncated": '{"pending": true, "groups": [',
            "not an object": "[]",
            "null": "null",
            "no pending": state([SYSTEM]) | {"pending": None},
            "pending as a word": state([SYSTEM], pending="yes"),
            "no groups": {"pending": True},
            "groups not a list": {"pending": True, "groups": "System packages"},
            "group without a name": state([{"items": [{"name": "a", "from": "", "to": ""}]}]),
            "group without items": state([{"name": "System packages"}]),
            "item without a name": state([{"name": "System packages", "items": [{"from": "1", "to": "2"}]}]),
            "item without versions": state([{"name": "System packages", "items": [{"name": "curl"}]}]),
            "item that is a word": state([{"name": "System packages", "items": ["curl"]}]),
        }
        for name, content in malformed.items():
            with self.subTest(name):
                self.write_updates(content)
                open(self.log, "w").close()
                result = self.run_notify()
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("vekrona-update-notify:", result.stderr)
                self.assertEqual([call[0] for call in self.calls()], ["vekrona-error"])
                self.assertFalse(os.path.exists(self.notified))

    def test_the_failure_is_reported_once_and_not_toasted_a_second_time(self):
        self.write_updates("lizard")
        self.run_notify()
        (call,) = self.calls()
        self.assertEqual(call[:2], ["vekrona-error", "report"])
        self.assertIn("vekrona-update-notify: cannot read", call[3])

    def test_a_failure_that_cannot_be_reported_is_toasted_as_critical(self):
        self.write_updates("lizard")
        self.run_notify(FAKE_REPORT_STATUS="1")
        report, toast = self.calls()
        self.assertEqual(report[:2], ["vekrona-error", "report"])
        self.assertEqual(toast[:3], ["notify-send", "-u", "critical"])


class DedupeTest(UpdateNotifyTestCase):
    def test_the_same_updates_are_announced_once(self):
        self.write_updates(state([SYSTEM]))
        self.run_notify()
        self.run_notify()
        self.assertEqual(len(self.asks()), 1)

    def test_a_different_set_of_updates_is_announced_again(self):
        self.write_updates(state([SYSTEM]))
        self.run_notify()
        self.write_updates(state([SYSTEM, FLATPAK]))
        self.run_notify()
        self.assertEqual(len(self.asks()), 2)

    def test_a_newer_version_of_a_listed_package_is_announced_again(self):
        self.write_updates(state([SYSTEM]))
        self.run_notify()
        newer = json.loads(json.dumps(SYSTEM))
        newer["items"][1]["to"] = "0.9.5"
        self.write_updates(state([newer]))
        self.run_notify()
        self.assertEqual(len(self.asks()), 2)

    def test_a_new_check_with_the_same_updates_is_not_announced_again(self):
        self.write_updates(state([SYSTEM]))
        self.run_notify()
        self.write_updates(state([SYSTEM], checked="2026-10-10T09:00:00+02:00", night_armed=False))
        self.run_notify()
        self.assertEqual(len(self.asks()), 1)

    def test_a_toast_nobody_answered_still_counts_as_shown(self):
        self.write_updates(state([SYSTEM]))
        for answer in ("timeout", "closed"):
            self.run_notify(answer)
        self.assertEqual(len(self.asks()), 1)

    def test_a_failed_ask_is_tried_again_next_time(self):
        self.write_updates(state([SYSTEM]))
        self.assertEqual(self.run_notify(FAKE_ASK_STATUS="1").returncode, 1)
        self.assertFalse(os.path.exists(self.notified))
        self.assertEqual(self.run_notify().returncode, 0)
        self.assertEqual(len(self.asks()), 2)


class AnswerTest(UpdateNotifyTestCase):
    def setUp(self):
        super().setUp()
        self.write_updates(state([SYSTEM]))

    def starts(self):
        return [call[1:] for call in self.calls() if call[0] == "vekrona-update-start"]

    def test_install_now_starts_the_online_update(self):
        self.assertEqual(self.run_notify("install").returncode, 0)
        self.assertEqual(self.starts(), [["vekrona-update-now.service"]])

    def test_not_tonight_starts_the_skip(self):
        self.assertEqual(self.run_notify("skip").returncode, 0)
        self.assertEqual(self.starts(), [["vekrona-update-skip.service"]])

    def test_no_answer_starts_nothing_because_the_night_run_takes_over(self):
        for answer in ("timeout", "closed"):
            with self.subTest(answer):
                self.assertEqual(self.run_notify(answer).returncode, 0)
        self.assertEqual(self.starts(), [])

    def test_an_answer_nobody_offered_is_an_error(self):
        result = self.run_notify("lizard")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.starts(), [])

    def test_a_unit_that_fails_to_start_fails_the_run(self):
        self.assertEqual(self.run_notify("install", FAKE_START_STATUS="1").returncode, 1)


if __name__ == "__main__":
    unittest.main()
