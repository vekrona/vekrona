import os
import unittest

from harness import SandboxTestCase, report_entry, user_unit_failed_entry


class WatcherResponsivenessTest(SandboxTestCase):
    def test_a_slow_context_capture_does_not_stall_the_watcher(self):
        release = os.path.join(self.sandbox.root, "release")
        os.mkfifo(release)
        watcher = self.sandbox.start_watch(
            [user_unit_failed_entry("slow.service"), report_entry("quick error")],
            extra_env={"FAKE_RELEASE": release})
        self.addCleanup(watcher.kill)

        self.assertEqual(self.sandbox.next_notification()["summary"], "quick error")

        with open(release, "w") as fifo:
            fifo.write("go")
        self.assertEqual(self.sandbox.next_notification()["summary"], "slow.service failed")
        watcher.communicate(timeout=30)

    def test_the_context_is_stored_before_the_toast_is_shown(self):
        self.sandbox.watch([user_unit_failed_entry("demo.service")])
        error_id = self.sandbox.latest_error_id()
        shown = self.sandbox.run("show", error_id).stdout
        self.assertIn("$ systemctl --user status -- demo.service", shown)
        self.assertEqual(self.sandbox.sent_notifications()[0]["summary"], "demo.service failed")


if __name__ == "__main__":
    unittest.main()
