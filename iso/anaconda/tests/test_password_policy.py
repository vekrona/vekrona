import unittest

import _paths

from vekrona_signin.core.password_policy import PasswordState, minimum_length, validate

MIN_LENGTH = 8


class PasswordPolicyTest(unittest.TestCase):
    def test_nothing_typed_is_empty(self):
        self.assertEqual(validate("", "", MIN_LENGTH), PasswordState.EMPTY)

    def test_confirmation_alone_does_not_make_a_password(self):
        self.assertEqual(validate("", "longenough", MIN_LENGTH), PasswordState.EMPTY)

    def test_password_shorter_than_the_minimum_is_too_short(self):
        self.assertEqual(validate("short", "short", MIN_LENGTH), PasswordState.TOO_SHORT)

    def test_password_of_exactly_the_minimum_length_is_accepted(self):
        self.assertEqual(validate("12345678", "12345678", MIN_LENGTH), PasswordState.VALID)

    def test_too_short_is_reported_before_mismatch(self):
        self.assertEqual(validate("short", "other", MIN_LENGTH), PasswordState.TOO_SHORT)

    def test_different_confirmation_is_a_mismatch(self):
        self.assertEqual(validate("longenough", "longenougH", MIN_LENGTH), PasswordState.MISMATCH)

    def test_missing_confirmation_is_a_mismatch(self):
        self.assertEqual(validate("longenough", "", MIN_LENGTH), PasswordState.MISMATCH)

    def test_matching_long_password_is_valid(self):
        self.assertEqual(validate("longenough", "longenough", MIN_LENGTH), PasswordState.VALID)

    def test_minimum_length_is_a_parameter(self):
        self.assertEqual(validate("12345678", "12345678", 12), PasswordState.TOO_SHORT)


class MinimumLengthTest(unittest.TestCase):
    def test_never_below_eight_even_if_anaconda_allows_less(self):
        self.assertEqual(minimum_length(6), 8)

    def test_a_stricter_luks_policy_wins(self):
        self.assertEqual(minimum_length(12), 12)


if __name__ == "__main__":
    unittest.main()
