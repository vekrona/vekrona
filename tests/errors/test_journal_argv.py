import unittest

from harness import SandboxTestCase


class JournalArgvTest(SandboxTestCase):
    # With --show-cursor journalctl prints a "-- cursor:" trailer when it ends, which is not JSON, and every entry's JSON
    # carries its __CURSOR already.
    def test_the_watcher_asks_journalctl_for_json_lines_only(self):
        self.sandbox.watch([])
        (follow,) = [call for call in self.sandbox.external_calls() if call.startswith("journalctl -f")]
        self.assertIn("-o json", follow)
        self.assertNotIn("--show-cursor", follow)


if __name__ == "__main__":
    unittest.main()
