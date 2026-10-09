import unittest

from harness import SandboxTestCase

MARKUP = '<img src="file:///etc/passwd"/> <a href="http://evil.example">click</a> a < b & c'


class NotificationBodyTest(SandboxTestCase):
    def test_journal_text_is_sent_unescaped_because_the_daemon_renders_no_markup(self):
        self.sandbox.watch([{
            "VEKRONA_TITLE": "markup in the log", "VEKRONA_SUMMARY": MARKUP,
            "SYSLOG_IDENTIFIER": "vekrona", "PRIORITY": "3", "MESSAGE": "m"}])
        notification = self.sandbox.sent_notifications()[0]
        self.assertIn(MARKUP, notification["body"])

    def test_the_title_stays_plain_text(self):
        self.sandbox.watch([{
            "VEKRONA_TITLE": "a < b", "SYSLOG_IDENTIFIER": "vekrona", "PRIORITY": "3", "MESSAGE": "m"}])
        self.assertEqual(self.sandbox.sent_notifications()[0]["summary"], "a < b")


if __name__ == "__main__":
    unittest.main()
