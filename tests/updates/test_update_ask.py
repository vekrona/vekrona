import signal
import unittest

from update_harness import UpdateAskTestCase

ASK = ["--timeout", "300", "--title", "Updates available", "--body", "System packages: curl 1 → 2",
       "--action", "install=Install now", "--action", "skip=Not tonight"]


class AnswerTest(UpdateAskTestCase):
    def ask_notification(self, daemon, *args):
        process = self.start_ask(*(args or ASK))
        return process, daemon.expect("notify")

    def test_the_notification_carries_the_title_body_and_actions_as_given(self):
        daemon = self.start_daemon()
        process, notification = self.ask_notification(daemon)
        self.assertEqual(
            (notification["summary"], notification["body"], notification["actions"]),
            ("Updates available", "System packages: curl 1 → 2", ["install", "Install now", "skip", "Not tonight"]))
        daemon.command(f"action {notification['id']} skip")
        self.finish(process)

    def test_the_answer_is_the_key_of_the_clicked_action_and_nothing_else_is_printed(self):
        daemon = self.start_daemon()
        process, notification = self.ask_notification(daemon)
        daemon.command(f"action {notification['id']} skip")
        self.assertEqual(self.finish(process), (0, "skip\n", ""))

    def test_dismissing_the_notification_answers_closed(self):
        daemon = self.start_daemon()
        process, notification = self.ask_notification(daemon)
        daemon.command(f"closed {notification['id']} 2")
        self.assertEqual(self.finish(process), (0, "closed\n", ""))

    def test_a_restart_of_the_notification_daemon_answers_closed(self):
        daemon = self.start_daemon()
        process, _ = self.ask_notification(daemon)
        daemon.command("release")
        self.assertEqual(self.finish(process), (0, "closed\n", ""))

    def test_no_answer_in_time_closes_the_notification_and_answers_timeout(self):
        daemon = self.start_daemon()
        process, notification = self.ask_notification(
            daemon, "--timeout", "0.2", *ASK[2:])
        self.assertEqual(daemon.expect("close")["id"], notification["id"])
        self.assertEqual(self.finish(process), (0, "timeout\n", ""))

    def assert_stopped_by(self, stop_signal):
        daemon = self.start_daemon()
        process, notification = self.ask_notification(daemon)
        process.send_signal(stop_signal)
        self.assertEqual(daemon.expect("close")["id"], notification["id"])
        self.assertEqual(self.finish(process), (0, "closed\n", ""))

    def test_sigterm_closes_the_notification_and_answers_closed(self):
        self.assert_stopped_by(signal.SIGTERM)

    def test_sigint_closes_the_notification_and_answers_closed(self):
        self.assert_stopped_by(signal.SIGINT)

    def test_sighup_closes_the_notification_and_answers_closed(self):
        self.assert_stopped_by(signal.SIGHUP)


class IgnoredSignalTest(UpdateAskTestCase):
    def assert_install_after(self, ignored_command_for):
        daemon = self.start_daemon()
        process = self.start_ask(*ASK)
        notification_id = daemon.expect("notify")["id"]
        daemon.command(ignored_command_for(notification_id))
        daemon.command(f"action {notification_id} install")
        self.assertEqual(self.finish(process), (0, "install\n", ""))

    def test_an_action_signal_from_a_sender_that_is_not_the_daemon_is_ignored(self):
        self.assert_install_after(lambda notification_id: f"forge-action {notification_id} skip")

    def test_a_closed_signal_from_a_sender_that_is_not_the_daemon_is_ignored(self):
        self.assert_install_after(lambda notification_id: f"forge-closed {notification_id} 2")

    def test_an_action_for_another_notification_is_ignored(self):
        self.assert_install_after(lambda notification_id: f"action {notification_id + 1} skip")

    def test_a_closing_of_another_notification_is_ignored(self):
        self.assert_install_after(lambda notification_id: f"closed {notification_id + 1} 2")

    def test_an_action_key_that_was_not_offered_is_ignored(self):
        self.assert_install_after(lambda notification_id: f"action {notification_id} default")


BODY = "<b>a</b> & b"


class BodySentThroughTheDaemon:
    def sent_body(self):
        daemon = self.start_daemon()
        process = self.start_ask("--timeout", "300", "--title", "t", "--body", BODY, "--action", "ok=OK")
        notification = daemon.expect("notify")
        daemon.command(f"action {notification['id']} ok")
        self.finish(process)
        return notification["body"]


class PlainDaemonBodyTest(BodySentThroughTheDaemon, UpdateAskTestCase):
    def test_the_body_is_sent_as_it_is_because_the_shell_shows_no_markup(self):
        self.assertEqual(self.sent_body(), BODY)


class FailureTest(UpdateAskTestCase):
    def test_no_notification_daemon_is_an_error_with_no_answer(self):
        status, stdout, stderr = self.run_ask(*ASK)
        self.assertNotEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertIn("vekrona-update-ask:", stderr)

    def test_its_failure_is_left_to_the_caller_to_record_and_is_not_toasted_here(self):
        self.run_ask(*ASK)
        with open(self.notify_send_log) as f:
            self.assertEqual(f.read(), "")

    def test_a_failure_to_close_the_notification_after_the_timeout_is_an_error_with_no_answer(self):
        daemon = self.start_daemon()
        daemon.command("fail-close")
        process = self.start_ask("--timeout", "0.2", *ASK[2:])
        daemon.expect("notify")
        status, stdout, stderr = self.finish(process)
        self.assertNotEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertIn("failed to close the notification", stderr)

    def test_a_failure_to_close_the_notification_when_stopped_is_an_error_with_no_answer(self):
        daemon = self.start_daemon()
        daemon.command("fail-close")
        process = self.start_ask(*ASK)
        daemon.expect("notify")
        process.send_signal(signal.SIGTERM)
        status, stdout, stderr = self.finish(process)
        self.assertNotEqual(status, 0)
        self.assertEqual(stdout, "")
        self.assertIn("failed to close the notification", stderr)


class ArgumentsTest(UpdateAskTestCase):
    def test_bad_arguments_are_refused_before_anything_is_sent(self):
        bad = {
            "no actions": ["--timeout", "5", "--title", "t", "--body", "b"],
            "zero timeout": ["--timeout", "0", *ASK[2:]],
            "negative timeout": ["--timeout", "-1", *ASK[2:]],
            "NaN timeout": ["--timeout", "nan", *ASK[2:]],
            "infinite timeout": ["--timeout", "inf", *ASK[2:]],
            "word timeout": ["--timeout", "lizard", *ASK[2:]],
            "action without a label": ["--timeout", "5", "--title", "t", "--body", "b", "--action", "key"],
            "action with an empty label": ["--timeout", "5", "--title", "t", "--body", "b", "--action", "key="],
            "action with an empty key": ["--timeout", "5", "--title", "t", "--body", "b", "--action", "=Label"],
            "action key that looks like an answer": ["--timeout", "5", "--title", "t", "--body", "b",
                                                      "--action", "timeout=Label"],
            "action key with a newline": ["--timeout", "5", "--title", "t", "--body", "b", "--action", "a\nb=L"],
            "duplicate action keys": ["--timeout", "5", "--title", "t", "--body", "b",
                                       "--action", "a=One", "--action", "a=Two"],
        }
        for name, args in bad.items():
            with self.subTest(name):
                status, stdout, _ = self.run_ask(*args)
                self.assertEqual((status, stdout), (2, ""))

    def test_a_label_may_contain_an_equals_sign(self):
        daemon = self.start_daemon()
        process = self.start_ask("--timeout", "300", "--title", "t", "--body", "b", "--action", "k=a=b")
        notification = daemon.expect("notify")
        self.assertEqual(notification["actions"], ["k", "a=b"])
        daemon.command(f"action {notification['id']} k")
        self.finish(process)


if __name__ == "__main__":
    unittest.main()
