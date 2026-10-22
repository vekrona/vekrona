import unittest

from harness import SandboxTestCase, report_entry, user_unit_failed_entry


class WatcherResponsivenessTest(SandboxTestCase):
    def test_a_slow_context_capture_does_not_stall_the_watcher(self):
        watcher = self.sandbox.start_watch(
            [user_unit_failed_entry("slow.service"), report_entry("quick error")],
            extra_env=self.sandbox.hold_context_captures())

        self.sandbox.wait_until_listed("quick error")

        self.sandbox.release_context_captures()
        watcher.communicate(timeout=30)
        shown = self.sandbox.run("show", self.sandbox.error_id_titled("slow.service failed")).stdout
        self.assertIn("$ systemctl --user status -- slow.service", shown)

    def test_the_context_is_stored_with_the_record(self):
        self.sandbox.watch([user_unit_failed_entry("demo.service")])
        error_id = self.sandbox.latest_error_id()
        shown = self.sandbox.run("show", error_id).stdout
        self.assertIn("$ systemctl --user status -- demo.service", shown)


if __name__ == "__main__":
    unittest.main()
