import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _paths
from test_luks_keyslot import DEVICE, ENROLLMENT, EXISTING_PASSPHRASE, LUKS_UUID, FakeCryptsetupTest

from vekrona_signin.core.crypttab import LuksDevice, enable_fido2_unlock, require_fido2_unlock_support
from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.luks_layout import LuksLayout
from vekrona_signin.service import installation
from vekrona_signin.core.fido2_luks import FidoLuksEnrollment
from vekrona_signin.service import vekrona_signin as service_module
from vekrona_signin.service.enrollment import SecurityKeyRegistration
from vekrona_signin.service.installation import LuksFido2Task
from vekrona_signin.service.vekrona_signin import VekronaSignInService

FIXTURES = Path(__file__).resolve().parents[3] / "tests/fixtures/crypttab"
UUID_PREFIX = "0a1b2c3d-0000-4000-8000-00000000000"
TOKEN_DEVICES = [LuksDevice(f"/dev/vda{n}", f"{UUID_PREFIX}{n}") for n in (1, 3, 4)]


class Sysroot:
    def __init__(self, test):
        self.path = Path(tempfile.mkdtemp())
        test.addCleanup(shutil.rmtree, self.path)
        (self.path / "etc").mkdir()

    @property
    def crypttab(self):
        return self.path / "etc/crypttab"

    def install_crypttab(self, content):
        self.crypttab.write_text(content)

    def install_fido2_support(self):
        (self.path / "usr/lib64/cryptsetup").mkdir(parents=True)
        (self.path / "usr/lib64/cryptsetup/libcryptsetup-token-systemd-fido2.so").touch()
        (self.path / "usr/lib64/libfido2.so.1.16.0").touch()


class CrypttabTest(unittest.TestCase):
    def setUp(self):
        self.sysroot = Sysroot(self)
        self.installer = (FIXTURES / "installer").read_text()
        self.expected = (FIXTURES / "fido2-enabled").read_text()
        self.sysroot.install_crypttab(self.installer)

    def test_token_devices_gain_the_options_and_everything_else_is_preserved(self):
        enable_fido2_unlock(self.sysroot.path, TOKEN_DEVICES)
        self.assertEqual(self.sysroot.crypttab.read_text(), self.expected)

    def test_a_prepared_crypttab_is_left_unchanged(self):
        enable_fido2_unlock(self.sysroot.path, TOKEN_DEVICES)
        enable_fido2_unlock(self.sysroot.path, TOKEN_DEVICES)
        self.assertEqual(self.sysroot.crypttab.read_text(), self.expected)

    def test_devices_without_a_token_are_left_alone(self):
        enable_fido2_unlock(self.sysroot.path, [LuksDevice("/dev/vda1", f"{UUID_PREFIX}1")])
        text = self.sysroot.crypttab.read_text()
        self.assertEqual(text.count("fido2-device="), 2)
        self.assertIn("none discard\n", text)

    def test_entry_named_by_device_path_is_matched(self):
        self.sysroot.install_crypttab("data /dev/vdb none\n")
        enable_fido2_unlock(self.sysroot.path, [LuksDevice("/dev/vdb", "ignored")])
        self.assertEqual(
            self.sysroot.crypttab.read_text(), "data /dev/vdb none fido2-device=auto,token-timeout=10s\n"
        )

    def test_uuid_case_does_not_matter(self):
        self.sysroot.install_crypttab("luks-x UUID=ABCDEF none\n")
        enable_fido2_unlock(self.sysroot.path, [LuksDevice("/dev/vdb", "abcdef")])
        self.assertIn("fido2-device=auto", self.sysroot.crypttab.read_text())

    def test_enrolled_device_without_an_entry_is_reported_by_path(self):
        with self.assertRaisesRegex(SignInError, "no entry for the enrolled LUKS device.*/dev/vdz"):
            enable_fido2_unlock(self.sysroot.path, [LuksDevice("/dev/vdz", "feedface")])
        self.assertEqual(self.sysroot.crypttab.read_text(), self.installer)

    def test_missing_crypttab_is_reported_with_its_path(self):
        self.sysroot.crypttab.unlink()
        with self.assertRaisesRegex(SignInError, "Cannot read .*etc/crypttab"):
            enable_fido2_unlock(self.sysroot.path, TOKEN_DEVICES)


class TargetSupportTest(unittest.TestCase):
    def setUp(self):
        self.sysroot = Sysroot(self)

    def test_a_system_with_the_token_library_and_libfido2_is_accepted(self):
        self.sysroot.install_fido2_support()
        require_fido2_unlock_support(self.sysroot.path)

    def test_missing_token_library_names_the_package(self):
        with self.assertRaisesRegex(SignInError, "libcryptsetup-token-systemd-fido2.*systemd-udev"):
            require_fido2_unlock_support(self.sysroot.path)

    def test_missing_libfido2_names_the_package(self):
        self.sysroot.install_fido2_support()
        (self.sysroot.path / "usr/lib64/libfido2.so.1.16.0").unlink()
        with self.assertRaisesRegex(SignInError, "libfido2"):
            require_fido2_unlock_support(self.sysroot.path)


class LuksFido2TaskTest(FakeCryptsetupTest):
    def setUp(self):
        super().setUp()
        self.sysroot = Sysroot(self)
        self.sysroot.install_fido2_support()
        self.sysroot.install_crypttab(
            f"luks-{LUKS_UUID} UUID={LUKS_UUID} none x-initrd.attach\n"
            "luks-other UUID=other none discard\n"
        )
        self.task = LuksFido2Task(self.sysroot.path, ENROLLMENT, None)

    def run_task(self, backing_paths=(DEVICE,), method="AUTOMATIC", task=None):
        applied = mock.Mock(PartitioningMethod=method)
        layout = LuksLayout(tuple(backing_paths), ())
        with mock.patch.object(installation, "STORAGE"), \
                mock.patch.object(installation, "applied_partitioning", return_value=applied), \
                mock.patch.object(installation, "find_luks_passphrase", return_value=EXISTING_PASSPHRASE), \
                mock.patch.object(installation, "find_luks_backing_paths", return_value=list(backing_paths)), \
                mock.patch.object(installation, "read_luks_layout", return_value=layout):
            (task or self.task).run()

    def manual_task(self, passphrase):
        return LuksFido2Task(self.sysroot.path, ENROLLMENT, passphrase)

    def test_the_enrolled_device_unlocks_with_the_key_on_the_first_boot(self):
        self.run_task()
        self.assertEqual(
            self.sysroot.crypttab.read_text(),
            f"luks-{LUKS_UUID} UUID={LUKS_UUID} none x-initrd.attach,fido2-device=auto,token-timeout=10s\n"
            "luks-other UUID=other none discard\n",
        )

    def test_a_target_without_fido2_support_fails_before_any_keyslot_is_added(self):
        shutil.rmtree(self.sysroot.path / "usr")
        with self.assertRaisesRegex(SignInError, "lacks libcryptsetup-token-systemd-fido2"):
            self.run_task()
        self.assertEqual(self.calls("luksAddKey"), [])

    def test_a_crypttab_without_the_enrolled_device_fails_the_task_with_the_cause(self):
        self.sysroot.install_crypttab("luks-other UUID=other none discard\n")
        with self.assertRaisesRegex(SignInError, "no entry for the enrolled LUKS device.*/dev/vda3"):
            self.run_task()

    def test_an_automatic_layout_uses_the_passphrase_of_the_applied_partitioning(self):
        self.run_task(task=self.manual_task("ignored for automatic layouts"))
        (add,) = self.calls("luksAddKey")
        self.assertEqual(add["key_file_content"], EXISTING_PASSPHRASE)

    def test_a_manual_layout_uses_the_passphrase_typed_on_the_sign_in_screen(self):
        self.run_task(method="INTERACTIVE", task=self.manual_task(EXISTING_PASSPHRASE))
        (add,) = self.calls("luksAddKey")
        self.assertEqual(add["key_file_content"], EXISTING_PASSPHRASE)
        self.assertIn("fido2-device=auto", self.sysroot.crypttab.read_text())

    def test_a_wrong_manual_passphrase_fails_the_task_naming_the_cause(self):
        with self.assertRaisesRegex(SignInError, "did not unlock /dev/vda3.*chosen during partitioning"):
            self.run_task(method="BLIVET", task=self.manual_task("mistyped"))
        self.assertEqual(self.calls("luksAddKey"), [])
        self.assertEqual(self.calls("token"), [])
        self.assertNotIn("fido2-device", self.sysroot.crypttab.read_text())

    def test_other_failures_of_a_manual_layout_keep_their_own_message(self):
        self.write_state(fail_token_import=True)
        with self.assertRaises(SignInError) as raised:
            self.run_task(method="INTERACTIVE", task=self.manual_task(EXISTING_PASSPHRASE))
        self.assertIn("token import refused", str(raised.exception))
        self.assertNotIn("did not unlock", str(raised.exception))

    def test_a_luks1_device_is_rejected_before_any_keyslot_is_added(self):
        state = self.state()
        state["luks1_devices"] = [DEVICE]
        self.state_path.write_text(json.dumps(state))
        for method, task in (("AUTOMATIC", None), ("INTERACTIVE", self.manual_task(EXISTING_PASSPHRASE))):
            with self.subTest(method):
                with self.assertRaisesRegex(SignInError, "/dev/vda3 is not a LUKS2 device"):
                    self.run_task(method=method, task=task)
        self.assertEqual(self.calls("luksAddKey"), [])

    def test_the_typed_passphrase_is_forgotten_after_the_task_ran(self):
        task = self.manual_task(EXISTING_PASSPHRASE)
        self.run_task(method="INTERACTIVE", task=task)
        with self.assertRaisesRegex(SignInError, "not entered on VEKRONA SIGN-IN"):
            self.run_task(method="INTERACTIVE", task=task)

    def service_task(self, service):
        conf = mock.Mock()
        conf.target.system_root = str(self.sysroot.path)
        with mock.patch.object(service_module, "conf", conf), \
                mock.patch.object(service_module, "USERS"), \
                mock.patch.object(service_module, "read_wheel_user", return_value=mock.Mock()) as wheel_user:
            wheel_user.return_value.name = "alice"
            return service.install_with_tasks()[0]

    def service_with_key(self):
        service = VekronaSignInService()
        service._security_key = SecurityKeyRegistration("alice", FidoLuksEnrollment(b"c", b"s", b"k"), "line")
        return service

    def test_the_passphrase_sent_to_the_service_reaches_cryptsetup(self):
        service = self.service_with_key()
        service.set_disk_passphrase(EXISTING_PASSPHRASE)
        self.run_task(method="INTERACTIVE", task=self.service_task(service))
        (add,) = self.calls("luksAddKey")
        self.assertEqual(add["key_file_content"], EXISTING_PASSPHRASE)

    def test_the_service_hands_the_passphrase_over_once(self):
        service = self.service_with_key()
        service.set_disk_passphrase(EXISTING_PASSPHRASE)
        self.service_task(service)
        with self.assertRaisesRegex(SignInError, "not entered on VEKRONA SIGN-IN"):
            self.run_task(method="INTERACTIVE", task=self.service_task(service))

    def test_clearing_or_dropping_the_key_forgets_the_passphrase(self):
        for forget in (lambda s: s.set_disk_passphrase(""), lambda s: s.forget_security_key()):
            with self.subTest(forget):
                service = self.service_with_key()
                service.set_disk_passphrase(EXISTING_PASSPHRASE)
                forget(service)
                service._store_security_key(self.service_with_key()._security_key)
                with self.assertRaisesRegex(SignInError, "not entered on VEKRONA SIGN-IN"):
                    self.run_task(method="INTERACTIVE", task=self.service_task(service))

    def test_a_wrong_automatic_passphrase_is_not_blamed_on_the_sign_in_screen(self):
        self.write_state(fail_token_import=False)
        state = self.state()
        state["existing_passphrase"] = "something else"
        self.state_path.write_text(json.dumps(state))
        with self.assertRaises(SignInError) as raised:
            self.run_task()
        self.assertNotIn("VEKRONA SIGN-IN", str(raised.exception))

    def test_a_manual_layout_with_luks_but_no_typed_passphrase_fails_before_any_keyslot_is_added(self):
        with self.assertRaisesRegex(SignInError, "not entered on VEKRONA SIGN-IN"):
            self.run_task(method="INTERACTIVE", task=self.manual_task(None))
        self.assertEqual(self.calls("luksAddKey"), [])

    def test_a_manual_layout_without_luks_has_no_disk_to_enroll_and_changes_nothing(self):
        before = self.sysroot.crypttab.read_text()
        self.run_task(backing_paths=(), method="INTERACTIVE", task=self.manual_task(None))
        self.assertEqual(self.calls("luksAddKey"), [])
        self.assertEqual(self.sysroot.crypttab.read_text(), before)


if __name__ == "__main__":
    unittest.main()
