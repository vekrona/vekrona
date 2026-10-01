import unittest

import _paths

from vekrona_account.field_feedback import FieldFeedback

ERRORS = {"username": "A username is required.", "hostname": None, "timezone": "Not a timezone."}


class FieldFeedbackTest(unittest.TestCase):
    def test_fresh_screen_shows_no_error(self):
        feedback = FieldFeedback()
        self.assertEqual(set(feedback.visible_errors(ERRORS).values()), {None})

    def test_error_appears_for_the_field_the_user_edited_only(self):
        feedback = FieldFeedback()
        feedback.edited("username")
        shown = feedback.visible_errors(ERRORS)
        self.assertEqual(shown["username"], ERRORS["username"])
        self.assertIsNone(shown["timezone"])

    def test_valid_edited_field_shows_nothing(self):
        feedback = FieldFeedback()
        feedback.edited("hostname")
        self.assertIsNone(feedback.visible_errors(ERRORS)["hostname"])

    def test_trying_to_leave_shows_every_error(self):
        feedback = FieldFeedback()
        feedback.leave_attempted()
        self.assertEqual(feedback.visible_errors(ERRORS), ERRORS)

    def test_reentering_the_screen_starts_clean(self):
        feedback = FieldFeedback()
        feedback.edited("username")
        feedback.leave_attempted()
        feedback.reset()
        self.assertEqual(set(feedback.visible_errors(ERRORS).values()), {None})


if __name__ == "__main__":
    unittest.main()
