import os
import unittest

from harness import SandboxTestCase


class UnreadFileTest(SandboxTestCase):
    def unread_path(self):
        return os.path.join(self.sandbox.store_dir(), "unread")

    def test_refreshing_in_a_fresh_state_creates_the_file_the_shell_watches(self):
        self.assertFalse(os.path.exists(self.sandbox.store_dir()))
        result = self.sandbox.run("refresh-unread")
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.unread_path()) as f:
            self.assertEqual(f.read(), "0\n")

    def test_refreshing_counts_the_errors_still_new(self):
        self.sandbox.ingest_report("service wedged")
        os.unlink(self.unread_path())
        result = self.sandbox.run("refresh-unread")
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(self.unread_path()) as f:
            self.assertEqual(f.read(), "1\n")


if __name__ == "__main__":
    unittest.main()
