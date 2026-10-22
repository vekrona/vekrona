import os
import unittest

from harness import SandboxTestCase


class WatcherPublishesUnreadTest(SandboxTestCase):
    def test_a_watcher_on_a_fresh_store_creates_the_unread_file_for_the_shell_to_watch(self):
        self.sandbox.watch([])
        self.assertEqual(self.sandbox.unread_count(), 0)

    def test_a_watcher_restores_an_unread_file_that_went_missing(self):
        self.sandbox.ingest_report("still unread")
        os.unlink(os.path.join(self.sandbox.store_dir(), "unread"))
        self.sandbox.watch([])
        self.assertEqual(self.sandbox.unread_count(), 1)


if __name__ == "__main__":
    unittest.main()
