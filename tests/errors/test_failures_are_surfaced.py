import os
import pwd
import stat
import unittest

from harness import SandboxTestCase, report_entry


class FailuresAreSurfacedTest(SandboxTestCase):
    def test_a_line_that_is_not_json_is_recorded_as_an_error_and_later_entries_still_land(self):
        result = self.sandbox.watch(["{this is not json", report_entry("after the bad line")])
        self.assertIn("not JSON", result.stderr)
        listed = self.sandbox.run("list").stdout
        self.assertIn("skipped a journalctl line that is not JSON", listed)
        self.assertIn("after the bad line", listed)

    def test_an_error_that_cannot_be_recorded_falls_back_to_a_plain_toast(self):
        self.sandbox.make_the_store_unwritable()
        result = self.sandbox.watch(["{this is not json"])
        self.assertIn("recording it failed", result.stderr)
        (toast,) = self.sandbox.toasts_mentioning("not JSON")
        self.assertEqual(toast["summary"], "vekrona-error")
        self.assertEqual(toast["actions"], [])

    def test_an_error_that_cannot_be_recorded_right_after_boot_still_falls_back_to_a_toast(self):
        self.sandbox.make_the_store_unwritable()
        self.sandbox.watch(["{this is not json"], just_booted=True)
        (toast,) = self.sandbox.toasts_mentioning("not JSON")
        self.assertEqual(toast["summary"], "vekrona-error")

    def test_a_repeating_error_that_cannot_be_recorded_is_toasted_once_a_minute(self):
        self.sandbox.make_the_store_unwritable()
        self.sandbox.watch(["{this is not json", "{this is not json either"])
        self.assertEqual(len(self.sandbox.toasts_mentioning("not JSON")), 1)

    def test_a_store_that_cannot_hold_the_unread_count_is_surfaced_at_start(self):
        self.sandbox.make_the_store_unwritable()
        result = self.sandbox.watch([])
        self.assertIn("cannot write the unread count", result.stderr)
        self.assertEqual(len(self.sandbox.toasts_mentioning("cannot write the unread count")), 1)

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

    def test_a_report_that_cannot_reach_the_journal_fails_without_a_toast_of_its_own(self):
        result = self.sandbox.run("report", "--title", "lost", extra_env={"HOME": pwd.getpwuid(os.getuid()).pw_dir, "VEKRONA_JOURNAL_SOCKET": "/nonexistent/journal"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to write to the journal", result.stderr)
        self.assertEqual(self.sandbox.external_calls(), [])
        self.assertEqual(self.sandbox.sent_notifications(), [])


if __name__ == "__main__":
    unittest.main()
