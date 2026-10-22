import os
import socket
import unittest

from harness import SandboxTestCase


class RefreshUnreadFailureTest(SandboxTestCase):
    def test_a_store_that_cannot_be_written_is_reported_to_the_journal_and_fails(self):
        journal = os.path.join(self.sandbox.root, "journal.sock")
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(listener.close)
        listener.bind(journal)
        listener.settimeout(10)
        self.sandbox.make_the_store_unwritable()

        result = self.sandbox.run("refresh-unread", extra_env={"VEKRONA_JOURNAL_SOCKET": journal})

        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot write the unread count", result.stderr)
        self.assertIn(b"VEKRONA_TITLE=cannot write the unread count", listener.recv(65536))

    def test_a_journal_that_cannot_be_reached_is_named_in_the_failure(self):
        self.sandbox.make_the_store_unwritable()
        result = self.sandbox.run("refresh-unread", extra_env={"VEKRONA_JOURNAL_SOCKET": "/nonexistent/journal"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("and writing it to the journal failed", result.stderr)


if __name__ == "__main__":
    unittest.main()
