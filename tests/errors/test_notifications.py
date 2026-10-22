import subprocess
import sys
import unittest

from harness import SandboxTestCase

MARKUP = '<img src="file:///etc/passwd"/> <a href="http://evil.example">click</a> a < b & c'


# vekrona-shell shows a notification body as plain text and advertises no body markup, so every toast carries its text as it is:
# an escaped body would show up as literal &amp; and &lt;.
class NotificationBodyTest(SandboxTestCase):
    # The only notification the watcher sends is the fallback for an error that cannot be recorded, whose text comes from the journal.
    def test_journal_text_is_sent_unescaped(self):
        self.sandbox.make_the_store_unwritable()
        self.sandbox.watch(["{" + MARKUP])
        self.assertIn(MARKUP, self.sandbox.toasts_mentioning("not JSON")[0]["body"])

    def test_the_last_resort_toast_of_a_failing_tool_is_sent_unescaped(self):
        subprocess.run([sys.executable, "-c", "import sys; sys.path.insert(0, sys.argv[1]); import vekrona_cli; "
                        "vekrona_cli.notify_send('tool', sys.argv[2])", self.sandbox.lib, MARKUP],
                       env=self.sandbox.env, check=True)
        (call,) = self.sandbox.notify_send_calls()
        self.assertTrue(call.endswith(f" -- tool {MARKUP}"), call)


if __name__ == "__main__":
    unittest.main()
