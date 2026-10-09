import unittest

from harness import SandboxTestCase

MARKUP = '<img src="file:///etc/passwd"/> <a href="http://evil.example">click</a> a < b & c'


ESCAPED_MARKUP = '&lt;img src="file:///etc/passwd"/&gt; &lt;a href="http://evil.example"&gt;click&lt;/a&gt; a &lt; b &amp; c'


def watch_markup(sandbox):
    sandbox.watch([{
        "VEKRONA_TITLE": "markup in the log", "VEKRONA_SUMMARY": MARKUP,
        "SYSLOG_IDENTIFIER": "vekrona", "PRIORITY": "3", "MESSAGE": "m"}])
    return sandbox.sent_notifications()[0]


class NotificationBodyTest(SandboxTestCase):
    def test_journal_text_is_sent_unescaped_because_the_daemon_renders_no_markup(self):
        self.assertIn(MARKUP, watch_markup(self.sandbox)["body"])

    def test_the_title_stays_plain_text(self):
        self.sandbox.watch([{
            "VEKRONA_TITLE": "a < b", "SYSLOG_IDENTIFIER": "vekrona", "PRIORITY": "3", "MESSAGE": "m"}])
        self.assertEqual(self.sandbox.sent_notifications()[0]["summary"], "a < b")


class MarkupDaemonBodyTest(SandboxTestCase):
    DAEMON_CAPABILITIES = "actions,body,body-markup"

    def test_journal_text_is_escaped_because_the_daemon_renders_markup(self):
        notification = watch_markup(self.sandbox)
        self.assertIn(ESCAPED_MARKUP, notification["body"])
        self.assertNotIn("<img", notification["body"])

    def test_the_title_stays_plain_text(self):
        self.sandbox.watch([{
            "VEKRONA_TITLE": "a < b", "SYSLOG_IDENTIFIER": "vekrona", "PRIORITY": "3", "MESSAGE": "m"}])
        self.assertEqual(self.sandbox.sent_notifications()[0]["summary"], "a < b")


if __name__ == "__main__":
    unittest.main()
