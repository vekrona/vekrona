import string
import unittest

from harness import SandboxTestCase, report_entry

BURST = 20


class RecordingIsSilentTest(SandboxTestCase):
    def test_recording_an_error_raises_no_notification_and_bumps_the_unread_count(self):
        self.sandbox.watch([report_entry("service wedged")])
        self.assertEqual(self.sandbox.sent_notifications(), [])
        self.assertEqual(self.sandbox.unread_count(), 1)

    def test_a_burst_of_errors_raises_no_notification(self):
        self.sandbox.watch([report_entry(f"burst {string.ascii_lowercase[i]}") for i in range(BURST)])
        self.assertEqual(self.sandbox.sent_notifications(), [])
        self.assertEqual(self.sandbox.unread_count(), BURST)

    def test_an_acked_error_that_recurs_raises_the_unread_count_again_without_a_notification(self):
        error_id = self.sandbox.ingest_report("service wedged")
        self.sandbox.run("ack", error_id)
        self.assertEqual(self.sandbox.unread_count(), 0)
        self.sandbox.watch([report_entry("service wedged")])
        self.assertEqual(self.sandbox.unread_count(), 1)
        self.assertEqual(self.sandbox.sent_notifications(), [])

    def test_a_watcher_failure_that_is_recorded_raises_no_notification(self):
        self.sandbox.watch(["{this is not json"])
        self.assertEqual(self.sandbox.unread_count(), 1)
        self.assertEqual(self.sandbox.sent_notifications(), [])


if __name__ == "__main__":
    unittest.main()
