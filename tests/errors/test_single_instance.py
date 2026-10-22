import unittest

from harness import SandboxTestCase, report_entry, user_unit_failed_entry


class SingleInstanceTest(SandboxTestCase):
    def test_a_second_watcher_refuses_to_start_and_duplicates_nothing(self):
        first = self.sandbox.start_watch(
            [user_unit_failed_entry("slow.service"), report_entry("only once")],
            extra_env=self.sandbox.hold_context_captures())
        self.sandbox.wait_until_listed("only once")

        second = self.sandbox.run("watch")
        self.assertEqual(second.returncode, 1)
        self.assertIn("already running", second.stderr)

        self.sandbox.release_context_captures()
        first.communicate(timeout=30)
        (row,) = [row for row in self.sandbox.run("list").stdout.splitlines() if "only once" in row]
        self.assertEqual(row.split()[3], "1")

    def test_the_lock_is_released_when_the_watcher_exits(self):
        self.assertIn("exited unexpectedly", self.sandbox.watch([]).stderr)
        self.assertIn("exited unexpectedly", self.sandbox.watch([]).stderr)


if __name__ == "__main__":
    unittest.main()
