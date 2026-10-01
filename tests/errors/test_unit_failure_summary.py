import unittest

from harness import (SandboxTestCase, system_unit_failed_entry, user_unit_exited_entry,
                     user_unit_failed_entry)


class UnitFailureSummaryTest(SandboxTestCase):
    def shown(self, error_id):
        out = self.sandbox.run("show", error_id).stdout
        return dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)

    def test_the_summary_says_the_unit_failed_and_why(self):
        self.sandbox.watch([
            user_unit_exited_entry("demo.service", "exited", "3"),
            user_unit_failed_entry("demo.service", "exit-code"),
        ])
        record = self.shown(self.sandbox.latest_error_id())
        self.assertEqual(record["title"], "demo.service failed")
        self.assertEqual(
            record["summary"],
            "demo.service failed with result 'exit-code'; main process exited (status 3)")

    def test_a_killed_unit_reports_the_signal(self):
        self.sandbox.watch([
            user_unit_exited_entry("demo.service", "killed", "9"),
            user_unit_failed_entry("demo.service", "signal"),
        ])
        summary = self.shown(self.sandbox.latest_error_id())["summary"]
        self.assertIn("main process killed (status 9)", summary)

    def test_without_a_recorded_exit_the_summary_still_names_the_result(self):
        self.sandbox.watch([system_unit_failed_entry("demo.service", "timeout")])
        summary = self.shown(self.sandbox.latest_error_id())["summary"]
        self.assertEqual(summary, "demo.service failed with result 'timeout'")

    def test_an_exit_is_not_reused_for_a_later_failure_of_another_unit(self):
        self.sandbox.watch([
            user_unit_exited_entry("a.service", "exited", "3"),
            user_unit_failed_entry("b.service", "exit-code"),
        ])
        summary = self.shown(self.sandbox.latest_error_id())["summary"]
        self.assertEqual(summary, "b.service failed with result 'exit-code'")


if __name__ == "__main__":
    unittest.main()
