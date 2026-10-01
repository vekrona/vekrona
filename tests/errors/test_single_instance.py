import os
import unittest

from harness import SandboxTestCase, report_entry, user_unit_failed_entry


class SingleInstanceTest(SandboxTestCase):
    def test_a_second_watcher_refuses_to_start_and_duplicates_nothing(self):
        release = os.path.join(self.sandbox.root, "release")
        os.mkfifo(release)
        first = self.sandbox.start_watch(
            [user_unit_failed_entry("slow.service"), report_entry("only once")],
            extra_env={"FAKE_RELEASE": release})
        self.addCleanup(first.kill)
        self.assertEqual(self.sandbox.next_notification()["summary"], "only once")

        second = self.sandbox.run("watch")
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", second.stderr)

        with open(release, "w") as fifo:
            fifo.write("go")
        first.communicate(timeout=30)
        titles = [n["summary"] for n in self.sandbox.sent_notifications()]
        self.assertEqual(titles.count("only once"), 1)

    def test_the_lock_is_released_when_the_watcher_exits(self):
        self.assertIn("exited unexpectedly", self.sandbox.watch([]).stderr)
        self.assertIn("exited unexpectedly", self.sandbox.watch([]).stderr)


if __name__ == "__main__":
    unittest.main()
