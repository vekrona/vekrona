import os
import stat
import unittest

from harness import SandboxTestCase, report_entry


class FailuresAreSurfacedTest(SandboxTestCase):
    def test_a_line_that_is_not_json_is_reported_and_later_entries_still_land(self):
        result = self.sandbox.watch(["{this is not json", report_entry("after the bad line")])
        self.assertIn("not JSON", result.stderr)
        self.assertIn("after the bad line", self.sandbox.run("list").stdout)
        self.assertEqual(self.sandbox.sent_notifications()[0]["summary"], "vekrona-errors")

    def test_a_corrupt_notification_map_is_reported_and_ignored(self):
        os.makedirs(self.sandbox.store_dir())
        with open(os.path.join(self.sandbox.store_dir(), "notifications.json"), "w") as f:
            f.write('{"owner": ":1.1", "map": [1, 2')
        result = self.sandbox.watch([report_entry("still recorded")])
        self.assertIn("corrupt notification map", result.stderr)
        self.assertIn("still recorded", self.sandbox.run("list").stdout)

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_a_corrupt_record_that_cannot_be_quarantined_is_not_reported_as_quarantined(self):
        error_id = self.sandbox.ingest_report("will be corrupted")
        record_dir = os.path.join(self.sandbox.store_dir(), error_id)
        with open(os.path.join(record_dir, "record.json"), "w") as f:
            f.write("{corrupt")
        os.chmod(record_dir, stat.S_IRUSR | stat.S_IXUSR)
        self.addCleanup(os.chmod, record_dir, stat.S_IRWXU)
        result = self.sandbox.run("show", error_id)
        self.assertIn("failed to quarantine a corrupt record", result.stderr)
        self.assertNotIn("\n[vekrona-error] quarantined", "\n" + result.stderr)

    def test_a_corrupt_record_that_can_be_moved_aside_is_quarantined(self):
        error_id = self.sandbox.ingest_report("will be corrupted")
        with open(os.path.join(self.sandbox.store_dir(), error_id, "record.json"), "w") as f:
            f.write("{corrupt")
        result = self.sandbox.run("show", error_id)
        self.assertIn("quarantined a corrupt record", result.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.sandbox.store_dir(), error_id, "record.json.corrupt")))

    def test_a_failing_notify_send_is_reported_by_die(self):
        result = self.sandbox.run("show", "20260101T000000-deadbeef", extra_env={"FAKE_NOTIFY_STATUS": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to show this error as a notification", result.stderr)
        self.assertIn("no notification daemon", result.stderr)

    def test_pick_with_nothing_to_pick_fails_when_the_notification_cannot_be_shown(self):
        result = self.sandbox.run("pick", extra_env={"FAKE_NOTIFY_STATUS": "1"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to show the notification", result.stderr)

    def test_pick_with_nothing_to_pick_notifies_and_succeeds(self):
        result = self.sandbox.run("pick")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("notify-send -u normal -a vekrona -- vekrona no errors recorded",
                      self.sandbox.external_calls())


if __name__ == "__main__":
    unittest.main()
