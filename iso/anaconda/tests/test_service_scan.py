import unittest
from unittest import mock

import _paths

from vekrona_signin.core.device_scan import DeviceScan, HintCode
from vekrona_signin.core.fido2_luks import FidoLuksEnrollment
from vekrona_signin.service import vekrona_signin as service_module
from vekrona_signin.service.enrollment import SecurityKeyRegistration
from vekrona_signin.service.vekrona_signin import VekronaSignInService
from vekrona_signin.service.vekrona_signin_interface import VekronaSignInInterface


def failed_scan():
    return DeviceScan.create([], "fido2 cannot be loaded. ImportError: boom", [], HintCode.LIBRARY_MISSING)


def registration(username):
    return SecurityKeyRegistration(username, FidoLuksEnrollment(b"c", b"s", b"k"), "line")


class ScanLoggingTest(unittest.TestCase):
    def test_problem_is_returned_and_logged_as_warning(self):
        service = VekronaSignInService()
        with mock.patch.object(service_module, "scan_security_keys", return_value=failed_scan()):
            with self.assertLogs(service_module.log, "WARNING") as logs:
                scan = service.scan_security_keys()
        self.assertEqual(scan.hint_code, HintCode.LIBRARY_MISSING)
        self.assertIn("ImportError: boom", logs.output[0])

    def test_successful_scan_logs_nothing(self):
        service = VekronaSignInService()
        ok = DeviceScan.create([], "", [], HintCode.NO_USB_DEVICE)
        with mock.patch.object(service_module.fprint, "scan_readers", return_value=ok):
            with self.assertNoLogs(service_module.log, "WARNING"):
                service.scan_fingerprint_readers()


class ForgetIfUserChangedTest(unittest.TestCase):
    def setUp(self):
        self.service = VekronaSignInService()
        self.service._store_security_key(registration("alice"))
        self.service._store_fingerprint("alice", object())

    def test_registrations_for_the_same_user_are_kept(self):
        self.assertFalse(self.service.forget_if_user_changed("alice"))
        self.assertTrue(self.service.security_key_registered)
        self.assertTrue(self.service.fingerprint_enrolled)

    def test_registrations_for_another_user_are_cleared(self):
        self.assertTrue(self.service.forget_if_user_changed("bob"))
        self.assertFalse(self.service.security_key_registered)
        self.assertFalse(self.service.fingerprint_enrolled)

    def test_only_the_mismatching_registration_is_cleared(self):
        self.service._store_fingerprint("bob", object())
        self.service.forget_if_user_changed("alice")
        self.assertTrue(self.service.security_key_registered)
        self.assertFalse(self.service.fingerprint_enrolled)

    def test_nothing_registered_means_nothing_forgotten(self):
        self.service.forget_security_key()
        self.service.forget_fingerprint()
        self.assertFalse(self.service.forget_if_user_changed("bob"))


class InterfaceTest(unittest.TestCase):
    def test_scan_crosses_dbus_as_a_structure(self):
        service = mock.Mock()
        service.scan_security_keys.return_value = failed_scan()
        structure = VekronaSignInInterface(service).ScanSecurityKeys()
        restored = DeviceScan.from_structure(structure)
        self.assertEqual(restored.hint_code, HintCode.LIBRARY_MISSING)
        self.assertIn("boom", restored.problem)


if __name__ == "__main__":
    unittest.main()
