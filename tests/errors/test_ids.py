import os
import unittest

from harness import SandboxTestCase

HOSTILE_IDS = ["../../etc", "..", "/etc/passwd", "20260101T000000-zzzzzzzz", "x", ""]


class ErrorIdValidationTest(SandboxTestCase):
    def test_every_id_taking_command_rejects_ids_that_are_not_generated_ids(self):
        outside = os.path.join(self.sandbox.root, "state", "vekrona", "escape")
        os.makedirs(outside)
        for command in ("show", "prompt", "ack", "mute", "rm"):
            for hostile in HOSTILE_IDS:
                with self.subTest(command=command, id=hostile):
                    result = self.sandbox.run(command, hostile)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn("not an error id", result.stderr)
        self.assertTrue(os.path.isdir(outside))

    def test_a_well_formed_but_unknown_id_is_reported_as_unknown(self):
        result = self.sandbox.run("show", "20260101T000000-deadbeef")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no such error", result.stderr)

    def test_the_id_of_a_recorded_error_is_accepted(self):
        error_id = self.sandbox.ingest_report("disk exploded")
        result = self.sandbox.run("show", error_id)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("disk exploded", result.stdout)


if __name__ == "__main__":
    unittest.main()
