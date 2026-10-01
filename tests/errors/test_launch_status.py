import unittest

from harness import SandboxTestCase


class LaunchStatusTest(SandboxTestCase):
    def status_of(self, error_id):
        for line in self.sandbox.run("list", "--all").stdout.splitlines():
            fields = line.split()
            if fields and fields[0] == error_id:
                return fields[2]
        self.fail(f"{error_id} not listed")

    def test_building_the_prompt_leaves_the_error_unread(self):
        error_id = self.sandbox.ingest_report("service wedged")
        result = self.sandbox.run("prompt", error_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status_of(error_id), "new")

    def test_marking_launched_takes_the_error_out_of_the_unread_state(self):
        error_id = self.sandbox.ingest_report("service wedged")
        result = self.sandbox.run("mark-launched", error_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.status_of(error_id), "launched")

    def test_marking_launched_keeps_a_muted_error_muted(self):
        error_id = self.sandbox.ingest_report("service wedged")
        self.sandbox.run("mute", error_id)
        self.sandbox.run("mark-launched", error_id)
        self.assertEqual(self.status_of(error_id), "muted")

    def test_marking_an_unknown_error_launched_fails(self):
        result = self.sandbox.run("mark-launched", "20260101T000000-deadbeef")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no such error", result.stderr)


if __name__ == "__main__":
    unittest.main()
