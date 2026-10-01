import unittest

import _paths

from vekrona_signin.gui.spokes.guidance import (
    INTRO, PASSWORD_LABEL, CONFIRM_LABEL, PASSWORD_HINT, ERR_PASSWORD_EMPTY,
    ERR_PASSWORD_SHORT, ERR_PASSWORD_MISMATCH, KEY_TITLE, KEY_WHAT, KEY_USE,
    KEY_STEPS, KEY_NONE, KEY_FOUND, KEY_DONE,
    PROBLEM_ACCESS, PROBLEM_LIBRARY, PROBLEM_UNUSABLE, FP_TITLE, FP_WHAT, FP_USE, FP_STEPS,
    FP_NONE, FP_FOUND, FP_DONE, DETAILS_TITLE, DETAILS_NO_USB,
    DISABLED_NO_ACCOUNT, NEED_PASSWORD_FIRST, USER_CHANGED, WATCH_UNAVAILABLE,
    STATUS_SET_PASSWORD, STATUS_PASSWORD_ONLY, STATUS_WITH_METHODS,
    STATUS_STORAGE_CHANGED, STATUS_ENCRYPTION_FAILED, STATUS_APPLYING, STATUS_CHOOSE_DISK_FIRST,
    STATUS_ENTER_DISK_PASSPHRASE, STATUS_DISK_PASSPHRASE_NOT_SAVED, STATUS_PASSWORD_NOT_SAVED, STATUS_STATE_UNREADABLE, DEFAULT_FINGER, password_state_error, device_scan_hint_to_key_text,
    device_scan_hint_to_fp_text, finger_choices,
)
from vekrona_signin.core.device_scan import HintCode
from vekrona_signin.gui.spokes import guidance
from vekrona_signin.core.fprint import FINGERS
from vekrona_signin.core.password_policy import PasswordState


class ConstantsTest(unittest.TestCase):
    def test_all_string_constants_are_non_empty(self):
        constants = [
            INTRO, PASSWORD_LABEL, CONFIRM_LABEL, PASSWORD_HINT,
            ERR_PASSWORD_EMPTY, ERR_PASSWORD_SHORT, ERR_PASSWORD_MISMATCH,
            KEY_TITLE, KEY_WHAT, KEY_USE, KEY_STEPS, KEY_NONE,
            KEY_FOUND, KEY_DONE, PROBLEM_ACCESS,
            PROBLEM_LIBRARY, PROBLEM_UNUSABLE, FP_TITLE, FP_WHAT, FP_USE, FP_STEPS, FP_NONE,
            FP_FOUND, FP_DONE, DETAILS_TITLE, DETAILS_NO_USB,
            DISABLED_NO_ACCOUNT, NEED_PASSWORD_FIRST, USER_CHANGED,
            WATCH_UNAVAILABLE, STATUS_SET_PASSWORD, STATUS_PASSWORD_ONLY,
            STATUS_WITH_METHODS, STATUS_STORAGE_CHANGED,
        ]
        for const in constants:
            self.assertIsNotNone(const)
            self.assertGreater(len(const), 0)

    def test_constants_with_placeholders_format_without_error(self):
        PASSWORD_HINT.format(n=8)
        ERR_PASSWORD_SHORT.format(n=8)
        KEY_FOUND.format(name="test")
        FP_FOUND.format(name="test")
        STATUS_WITH_METHODS.format(methods="test")

    def test_password_hint_with_n_8_contains_8(self):
        formatted = PASSWORD_HINT.format(n=8)
        self.assertIn("8", formatted)

    def test_err_password_short_with_n_8_contains_8(self):
        formatted = ERR_PASSWORD_SHORT.format(n=8)
        self.assertIn("8", formatted)

    def test_key_texts_mention_disk(self):
        self.assertIn("disk", KEY_USE.lower())

    def test_key_texts_mention_sudo(self):
        self.assertIn("sudo", KEY_USE.lower())

    def test_key_texts_mention_login(self):
        self.assertIn("login", KEY_USE.lower())

    def test_fingerprint_texts_say_it_cannot_unlock_disk(self):
        self.assertIn("cannot unlock the disk", FP_USE.lower())


HUB_TILE_MAX_CHARS = 48


class HubTileStatusTest(unittest.TestCase):
    def test_every_status_fits_the_two_line_hub_tile(self):
        statuses = {
            "set password": STATUS_SET_PASSWORD,
            "password only": STATUS_PASSWORD_ONLY,
            "all methods": STATUS_WITH_METHODS.format(methods="security key + fingerprint"),
            "storage changed": STATUS_STORAGE_CHANGED,
            "encryption failed": STATUS_ENCRYPTION_FAILED,
            "applying": STATUS_APPLYING,
            "choose disk first": STATUS_CHOOSE_DISK_FIRST,
            "enter disk passphrase": STATUS_ENTER_DISK_PASSPHRASE,
            "disk passphrase not saved": STATUS_DISK_PASSPHRASE_NOT_SAVED,
            "password not saved": STATUS_PASSWORD_NOT_SAVED,
            "state unreadable": STATUS_STATE_UNREADABLE,
            "no account": DISABLED_NO_ACCOUNT,
        }
        for name, text in statuses.items():
            with self.subTest(name):
                self.assertLessEqual(len(text), HUB_TILE_MAX_CHARS)


class PlainLanguageTest(unittest.TestCase):
    def test_jargon_acronyms_never_appear_in_screen_texts(self):
        for name in dir(guidance):
            value = getattr(guidance, name)
            if name.isupper() and isinstance(value, str):
                with self.subTest(name):
                    self.assertNotIn("LUKS", value)
                    self.assertNotIn("FIDO", value)

    def test_the_pin_is_explained_where_the_steps_introduce_it(self):
        self.assertIn("A PIN is a short code", KEY_STEPS)

    def test_sudo_comes_with_its_plain_meaning(self):
        for text in (KEY_USE, FP_USE):
            with self.subTest(text):
                self.assertIn("administrator actions (sudo)", text)


class PasswordStateTest(unittest.TestCase):
    def test_every_invalid_state_has_an_error(self):
        for state in (PasswordState.EMPTY, PasswordState.TOO_SHORT, PasswordState.MISMATCH):
            with self.subTest(state):
                self.assertTrue(password_state_error(state, 8))

    def test_too_short_names_the_minimum_length(self):
        self.assertIn("12", password_state_error(PasswordState.TOO_SHORT, 12))

    def test_valid_password_has_no_error(self):
        self.assertEqual(password_state_error(PasswordState.VALID, 8), "")

    def test_unknown_state_raises_value_error(self):
        with self.assertRaises(ValueError):
            password_state_error("VALID", 8)


class DeviceScanHintKeyTest(unittest.TestCase):
    def test_ok_needs_no_hint(self):
        self.assertIsNone(device_scan_hint_to_key_text(HintCode.OK))

    def test_every_problem_hint_has_a_text(self):
        for hint in (HintCode.NO_DEVICE, HintCode.DEVICE_UNUSABLE,
                     HintCode.ACCESS_DENIED, HintCode.LIBRARY_MISSING):
            with self.subTest(hint):
                self.assertTrue(device_scan_hint_to_key_text(hint))

    def test_no_device_is_the_plain_no_key_text(self):
        self.assertEqual(device_scan_hint_to_key_text(HintCode.NO_DEVICE), KEY_NONE)

    def test_a_failing_key_candidate_is_explained(self):
        self.assertEqual(device_scan_hint_to_key_text(HintCode.DEVICE_UNUSABLE), PROBLEM_UNUSABLE)

    def test_unknown_hint_raises_value_error(self):
        with self.assertRaises(ValueError):
            device_scan_hint_to_key_text("unknown")


class DeviceScanHintFpTest(unittest.TestCase):
    def test_ok_needs_no_hint(self):
        self.assertIsNone(device_scan_hint_to_fp_text(HintCode.OK))

    def test_no_device_is_the_plain_no_reader_text(self):
        self.assertEqual(device_scan_hint_to_fp_text(HintCode.NO_DEVICE), FP_NONE)

    def test_a_failing_reader_is_explained(self):
        self.assertEqual(device_scan_hint_to_fp_text(HintCode.DEVICE_UNUSABLE), PROBLEM_UNUSABLE)

    def test_every_problem_hint_has_a_text(self):
        for hint in (HintCode.NO_DEVICE, HintCode.DEVICE_UNUSABLE,
                     HintCode.ACCESS_DENIED, HintCode.LIBRARY_MISSING):
            with self.subTest(hint):
                self.assertTrue(device_scan_hint_to_fp_text(hint))

    def test_unknown_hint_raises_value_error(self):
        with self.assertRaises(ValueError):
            device_scan_hint_to_fp_text("unknown")


class FingerChoicesTest(unittest.TestCase):
    def test_choices_are_exactly_the_fingers_libfprint_knows(self):
        self.assertEqual({nick for nick, _ in finger_choices()}, set(FINGERS))

    def test_default_finger_is_a_choice(self):
        self.assertIn(DEFAULT_FINGER, dict(finger_choices()))


if __name__ == "__main__":
    unittest.main()
