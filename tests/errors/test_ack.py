import unittest

from harness import SandboxTestCase, report_entry


class AckTest(SandboxTestCase):
    def status_of(self, error_id):
        (row,) = [row for row in self.sandbox.run("list", "--all").stdout.splitlines() if row.startswith(error_id)]
        return row.split()[2]

    def three_new_errors(self):
        titles = ("first fault", "second fault", "third fault")
        self.sandbox.watch([report_entry(title) for title in titles])
        return [self.sandbox.error_id_titled(title) for title in titles]

    def test_acking_ids_marks_exactly_those_errors_seen(self):
        first, second, third = self.three_new_errors()
        result = self.sandbox.run("ack", first, second)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([self.status_of(i) for i in (first, second, third)], ["seen", "seen", "new"])
        self.assertEqual(self.sandbox.unread_count(), 1)

    def test_an_id_pruned_since_the_list_is_a_noted_no_op_and_the_rest_are_acked(self):
        known = self.three_new_errors()[0]
        result = self.sandbox.run("ack", "20260101T000000-deadbeef", known)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no such error, nothing to ack: 20260101T000000-deadbeef", result.stderr)
        self.assertEqual(self.status_of(known), "seen")
        self.assertEqual(result.stdout.splitlines(), [f"acked: {known}"])

    def test_a_vanished_id_raises_no_toast(self):
        self.sandbox.run("ack", "20260101T000000-deadbeef")
        self.assertEqual(self.sandbox.notify_send_calls(), [])

    def test_a_muted_error_stays_muted_and_is_not_reported_as_acked(self):
        error_id = self.three_new_errors()[0]
        self.sandbox.run("mute", error_id)
        result = self.sandbox.run("ack", error_id)
        self.assertEqual(self.status_of(error_id), "muted")
        self.assertEqual(result.stdout, "")

    def test_all_acks_every_new_error(self):
        ids = self.three_new_errors()
        self.assertEqual(self.sandbox.run("ack", "--all").returncode, 0)
        self.assertEqual([self.status_of(i) for i in ids], ["seen"] * 3)
        self.assertEqual(self.sandbox.unread_count(), 0)

    def test_ids_together_with_all_or_nothing_at_all_are_refused(self):
        error_id = self.three_new_errors()[0]
        for argv in (["ack", error_id, "--all"], ["ack"]):
            with self.subTest(argv=argv):
                result = self.sandbox.run(*argv)
                self.assertEqual(result.returncode, 1)
                self.assertIn("ack takes", result.stderr)
                self.assertEqual(self.sandbox.notify_send_calls(), [])
        self.assertEqual(self.status_of(error_id), "new")


if __name__ == "__main__":
    unittest.main()
