import os
import pwd
import socket

from harness import SandboxTestCase

TITLE = "scratch run failed"


class ReportHomeTest(SandboxTestCase):
    def setUp(self):
        super().setUp()
        self.journal = os.path.join(self.sandbox.root, "journal.sock")
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.addCleanup(self.listener.close)
        self.listener.bind(self.journal)
        self.listener.setblocking(False)

    def report(self, home):
        return self.sandbox.run("report", "--title", TITLE,
                                extra_env={"HOME": home, "VEKRONA_JOURNAL_SOCKET": self.journal})

    def received(self):
        try:
            return self.listener.recv(65536)
        except BlockingIOError:
            return None

    def test_a_scratch_home_cannot_write_to_the_real_journal(self):
        result = self.report(self.sandbox.env["HOME"])
        self.assertEqual(result.returncode, 1)
        self.assertIn(TITLE, result.stderr)
        self.assertIsNone(self.received())

    def test_the_users_own_home_reports(self):
        result = self.report(pwd.getpwuid(os.getuid()).pw_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"VEKRONA_TITLE={TITLE}".encode(), self.received())

    def test_a_link_to_the_users_home_is_still_the_users_home(self):
        link = os.path.join(self.sandbox.root, "home-link")
        os.symlink(pwd.getpwuid(os.getuid()).pw_dir, link)
        result = self.report(link)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNotNone(self.received())
