import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _paths
from test_luks_keyslot import DEVICE, ENROLLMENT, EXISTING_PASSPHRASE, LUKS_UUID, FakeCryptsetupTest

from vekrona_signin.core.crypttab import LuksDevice, enable_fido2_unlock, require_fido2_unlock_support
from vekrona_signin.core.errors import SignInError
from vekrona_signin.service import installation
from vekrona_signin.service.installation import LuksFido2Task

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
        self.task = LuksFido2Task(self.sysroot.path, ENROLLMENT)

    def run_task(self, backing_paths=(DEVICE,)):
        with mock.patch.object(installation, "STORAGE"), \
                mock.patch.object(installation, "find_luks_passphrase", return_value=EXISTING_PASSPHRASE), \
                mock.patch.object(installation, "find_luks_backing_paths", return_value=list(backing_paths)):
            self.task.run()

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


if __name__ == "__main__":
    unittest.main()
