import unittest

import _paths

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.device_scan import DeviceScan, HintCode
from vekrona_signin.gui.panel_view import (
    FINGERPRINT_PANEL,
    KEY_PANEL,
    PIN_MIN_LENGTH,
    PanelInput,
    panel_view,
    pin_form,
)
from vekrona_signin.gui.spokes import guidance

YUBIKEY_USB = "1050:0407 Yubico YubiKey OTP+FIDO+CCID"
YUBIKEY = DeviceDescription.create("/dev/hidraw3", "YubiKey OTP+FIDO+CCID (1050:0407)")


def scan(devices=(), problem="", usb_seen=(), hint=HintCode.NO_DEVICE):
    return DeviceScan.create(devices, problem, usb_seen, hint)


def found_key():
    return scan([YUBIKEY], usb_seen=[YUBIKEY_USB], hint=HintCode.OK)


def ready_input(**fields):
    values = {"password_valid": True}
    values.update(fields)
    return PanelInput(**values)


class EmptyResultsAreExplainedTest(unittest.TestCase):
    def test_nothing_plugged_in(self):
        view = panel_view(KEY_PANEL, ready_input(scan=scan()))
        self.assertEqual(view.state_text, guidance.KEY_NONE)
        self.assertEqual(view.details_text, guidance.DETAILS_NO_USB)
        self.assertEqual(view.devices, ())

    def test_unrelated_usb_devices_keep_the_plain_no_key_text_and_stay_in_details(self):
        mouse = "046d:c077 Logitech USB Optical Mouse"
        view = panel_view(KEY_PANEL, ready_input(scan=scan(usb_seen=[mouse])))
        self.assertEqual(view.state_text, guidance.KEY_NONE)
        self.assertIn(mouse, view.details_text)

    def test_key_candidate_that_failed_says_it_cannot_be_used(self):
        view = panel_view(KEY_PANEL, ready_input(scan=scan(
            usb_seen=[YUBIKEY_USB], problem="/dev/hidraw3: OSError: Inappropriate ioctl",
            hint=HintCode.DEVICE_UNUSABLE,
        )))
        self.assertEqual(view.state_text, guidance.PROBLEM_UNUSABLE)
        self.assertIn("Inappropriate ioctl", view.details_text)

    def test_details_separate_the_device_list_from_the_problem(self):
        view = panel_view(KEY_PANEL, ready_input(scan=scan(
            usb_seen=[YUBIKEY_USB], problem="2 HID nodes inspected.", hint=HintCode.DEVICE_UNUSABLE,
        )))
        self.assertEqual(
            view.details_text,
            f"{guidance.DETAILS_USB_SEEN}\n  {YUBIKEY_USB}\n\n{guidance.DETAILS_PROBLEM.format(problem='2 HID nodes inspected.')}",
        )

    def test_missing_library_names_the_failure(self):
        view = panel_view(FINGERPRINT_PANEL, ready_input(scan=scan(
            problem="libfprint (gi.repository.FPrint) cannot be loaded. ValueError: Namespace FPrint not available",
            hint=HintCode.LIBRARY_MISSING,
        )))
        self.assertEqual(view.state_text, guidance.PROBLEM_LIBRARY)
        self.assertIn("Namespace FPrint not available", view.details_text)

    def test_failed_scan_call_is_shown_in_state_and_details(self):
        view = panel_view(KEY_PANEL, ready_input(scan_error="org.freedesktop.DBus.Error.NoReply"))
        self.assertIn("NoReply", view.state_text)
        self.assertIn("NoReply", view.details_text)
        self.assertFalse(view.enroll_sensitive)

    def test_scan_in_flight_says_so(self):
        self.assertEqual(panel_view(KEY_PANEL, ready_input()).state_text, guidance.SCANNING)

    def test_missing_automatic_detection_is_mentioned(self):
        view = panel_view(KEY_PANEL, ready_input(scan=scan(), watch_available=False))
        self.assertIn(guidance.WATCH_UNAVAILABLE, view.state_text)


class ControlsAppearWithTheDeviceTest(unittest.TestCase):
    def test_without_a_device_no_setup_control_is_shown(self):
        for panel in (KEY_PANEL, FINGERPRINT_PANEL):
            with self.subTest(panel):
                view = panel_view(panel, ready_input(scan=scan()))
                self.assertFalse(view.show_setup)
                self.assertFalse(view.show_registered)

    def test_while_scanning_no_setup_control_is_shown(self):
        self.assertFalse(panel_view(KEY_PANEL, ready_input()).show_setup)

    def test_a_found_device_shows_the_setup_controls(self):
        self.assertTrue(panel_view(KEY_PANEL, ready_input(scan=found_key())).show_setup)

    def test_password_reminder_is_irrelevant_without_a_device(self):
        view = panel_view(KEY_PANEL, ready_input(scan=scan(), password_valid=False))
        self.assertEqual(view.password_hint, "")

    def test_password_reminder_is_irrelevant_once_registered(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), registered=True, password_valid=False))
        self.assertEqual(view.password_hint, "")


class SecurityKeyPanelTest(unittest.TestCase):
    def test_found_key_is_named_and_listed(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), selected_id=YUBIKEY.id))
        self.assertEqual(view.state_text, guidance.KEY_FOUND.format(name=YUBIKEY.name))
        self.assertEqual(view.devices, ((YUBIKEY.id, YUBIKEY.name),))
        self.assertIn(YUBIKEY_USB, view.details_text)

    def test_registration_needs_a_valid_password_first(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), selected_id=YUBIKEY.id, password_valid=False))
        self.assertFalse(view.enroll_sensitive)
        self.assertEqual(view.password_hint, guidance.NEED_PASSWORD_FIRST)
        self.assertNotIn(guidance.NEED_PASSWORD_FIRST, view.state_text)

    def test_registration_needs_a_selected_device(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), selected_id=None))
        self.assertFalse(view.enroll_sensitive)
        self.assertTrue(view.choose_sensitive)

    def test_valid_password_and_selected_key_allow_registration(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), selected_id=YUBIKEY.id))
        self.assertTrue(view.enroll_sensitive)
        self.assertEqual(view.password_hint, "")

    def test_running_task_locks_every_control(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), selected_id=YUBIKEY.id, busy=True))
        self.assertFalse(view.enroll_sensitive or view.choose_sensitive or view.check_sensitive
                         or view.remove_sensitive)

    def test_registered_key_offers_removal_instead_of_setup(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), selected_id=YUBIKEY.id, registered=True))
        self.assertEqual(view.state_text, guidance.KEY_DONE)
        self.assertTrue(view.show_registered)
        self.assertFalse(view.show_setup)
        self.assertFalse(view.enroll_sensitive)

    def test_renamed_user_is_told_to_register_again(self):
        view = panel_view(KEY_PANEL, ready_input(scan=found_key(), user_changed=True))
        self.assertTrue(view.state_text.startswith(guidance.USER_CHANGED))


class FingerprintPanelTest(unittest.TestCase):
    def test_a_yubikey_never_appears_as_a_fingerprint_reader(self):
        view = panel_view(FINGERPRINT_PANEL, ready_input(scan=scan(usb_seen=[YUBIKEY_USB])))
        self.assertEqual(view.devices, ())
        self.assertEqual(view.state_text, guidance.FP_NONE)
        self.assertFalse(view.enroll_sensitive)

    def test_found_reader_is_named(self):
        reader = DeviceDescription.create("goodix-0", "Goodix MOC Fingerprint Sensor")
        view = panel_view(FINGERPRINT_PANEL, ready_input(scan=scan([reader], hint=HintCode.OK),
                                                          selected_id="goodix-0"))
        self.assertEqual(view.state_text, guidance.FP_FOUND.format(name=reader.name))
        self.assertTrue(view.enroll_sensitive)


class PinFormTest(unittest.TestCase):
    def test_key_with_a_pin_asks_for_it_once(self):
        form = pin_form("", "", key_has_pin=True)
        self.assertEqual(form.label, guidance.KEY_PIN_LABEL)
        self.assertFalse(form.confirm_visible)
        self.assertFalse(form.acceptable)
        self.assertEqual(form.error, "")

    def test_existing_pin_is_accepted_as_typed(self):
        self.assertTrue(pin_form("1", "", key_has_pin=True).acceptable)

    def test_key_without_a_pin_asks_for_a_new_one_twice(self):
        form = pin_form("", "", key_has_pin=False)
        self.assertEqual(form.label, guidance.KEY_NEW_PIN_LABEL)
        self.assertTrue(form.confirm_visible)
        self.assertIn(str(PIN_MIN_LENGTH), form.hint)

    def test_short_new_pin_is_rejected(self):
        form = pin_form("12", "12", key_has_pin=False)
        self.assertFalse(form.acceptable)
        self.assertEqual(form.error, guidance.ERR_PIN_SHORT.format(n=PIN_MIN_LENGTH))

    def test_new_pin_needs_the_same_confirmation(self):
        form = pin_form("1234", "1235", key_has_pin=False)
        self.assertFalse(form.acceptable)
        self.assertEqual(form.error, guidance.ERR_PIN_MISMATCH)

    def test_unfinished_confirmation_is_not_an_error_yet(self):
        form = pin_form("1234", "", key_has_pin=False)
        self.assertFalse(form.acceptable)
        self.assertEqual(form.error, "")

    def test_matching_new_pin_is_accepted(self):
        self.assertTrue(pin_form("1234", "1234", key_has_pin=False).acceptable)


if __name__ == "__main__":
    unittest.main()
