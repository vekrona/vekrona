import unittest
from unittest import mock

import _paths

from pyanaconda.modules.common.structures.partitioning import PartitioningRequest
from pyanaconda.modules.common.structures.storage import DeviceData, DeviceFormatData

from vekrona_signin.core.errors import SignInError
from vekrona_signin.service import enrollment
from vekrona_signin.service.enrollment import SecurityKeyRegistrationTask
from vekrona_signin.service.installation import find_luks_backing_paths, find_luks_passphrase

APPLIED_PATH = "/org/fedoraproject/Anaconda/Modules/Storage/Partitioning/2"


def partitioning_with(passphrase, encrypted=True):
    request = PartitioningRequest()
    request.encrypted = encrypted
    request.passphrase = passphrase
    return mock.Mock(Request=PartitioningRequest.to_structure(request))


class FakeStorage:
    def __init__(self, applied):
        self.AppliedPartitioning = applied


class LuksPassphraseTest(unittest.TestCase):
    def test_passphrase_comes_from_the_applied_partitioning(self):
        proxies = {APPLIED_PATH: partitioning_with("secret-passphrase")}
        result = find_luks_passphrase(FakeStorage(APPLIED_PATH), proxies.__getitem__)
        self.assertEqual(result, "secret-passphrase")

    def test_unencrypted_applied_partitioning_is_rejected(self):
        proxies = {APPLIED_PATH: partitioning_with("secret-passphrase", encrypted=False)}
        with self.assertRaisesRegex(SignInError, "not encrypted"):
            find_luks_passphrase(FakeStorage(APPLIED_PATH), proxies.__getitem__)

    def test_missing_applied_partitioning_is_reported(self):
        with self.assertRaisesRegex(SignInError, "No partitioning has been applied"):
            find_luks_passphrase(FakeStorage(""), {}.__getitem__)

    def test_empty_passphrase_is_reported(self):
        proxies = {APPLIED_PATH: partitioning_with("")}
        with self.assertRaisesRegex(SignInError, "no LUKS passphrase"):
            find_luks_passphrase(FakeStorage(APPLIED_PATH), proxies.__getitem__)


class FakeDeviceTree:
    def __init__(self, devices, mount_points):
        self._devices = devices
        self._mount_points = mount_points

    def GetDevices(self):
        return list(self._devices)

    def GetMountPoints(self):
        return dict(self._mount_points)

    def GetAncestors(self, device_ids):
        ancestors = set()
        pending = list(device_ids)
        while pending:
            for parent in self._devices[pending.pop()]["parents"]:
                ancestors.add(parent)
                pending.append(parent)
        return sorted(ancestors)

    def GetDeviceData(self, device_id):
        data = DeviceData()
        data.device_id = device_id
        data.path = self._devices[device_id]["path"]
        return DeviceData.to_structure(data)

    def GetFormatData(self, device_id):
        data = DeviceFormatData()
        data.type = self._devices[device_id]["format"]
        return DeviceFormatData.to_structure(data)


def device(path, format_type, parents=()):
    return {"path": path, "format": format_type, "parents": list(parents)}


class LuksDeviceSelectionTest(unittest.TestCase):
    def setUp(self):
        self.devices = {
            "vda": device("/dev/vda", "disklabel"),
            "vda1": device("/dev/vda1", "efi", ["vda"]),
            "vda2": device("/dev/vda2", "ext4", ["vda"]),
            "vda3": device("/dev/vda3", "luks", ["vda"]),
            "luks-root": device("/dev/mapper/luks-root", "btrfs", ["vda3"]),
            "vdb": device("/dev/vdb", "disklabel"),
            "vdb1": device("/dev/vdb1", "luks", ["vdb"]),
            "luks-old": device("/dev/mapper/luks-old", "ext4", ["vdb1"]),
        }
        self.mount_points = {"/": "luks-root", "/boot": "vda2", "/boot/efi": "vda1"}

    def chosen(self):
        return find_luks_backing_paths(FakeDeviceTree(self.devices, self.mount_points))

    def test_luks_device_backing_the_root_filesystem_is_chosen(self):
        self.assertEqual(self.chosen(), ["/dev/vda3"])

    def test_preexisting_luks_device_that_is_not_part_of_the_system_is_left_alone(self):
        self.assertNotIn("/dev/vdb1", self.chosen())

    def test_kept_luks_device_mounted_into_the_system_is_chosen(self):
        self.mount_points["/data"] = "luks-old"
        self.assertEqual(self.chosen(), ["/dev/vda3", "/dev/vdb1"])

    def test_system_without_luks_is_reported(self):
        self.mount_points = {"/boot": "vda2"}
        with self.assertRaisesRegex(SignInError, "No LUKS device"):
            self.chosen()


class RegistrationPinTest(unittest.TestCase):
    def registration_task(self):
        return SecurityKeyRegistrationTask("/dev/hidraw3", "1234", False, "alice")

    def test_pin_is_forgotten_after_a_successful_registration(self):
        task = self.registration_task()
        with mock.patch.object(enrollment, "opened_security_key"), \
                mock.patch.object(enrollment.fido2_luks, "enroll"), \
                mock.patch.object(enrollment.pam_u2f, "register", return_value="alice:line"):
            task.run()
        self.assertIsNotNone(task.registration)
        self.assertNotIn("1234", repr(vars(task)))

    def test_pin_is_forgotten_after_a_failed_registration(self):
        task = self.registration_task()
        with mock.patch.object(enrollment, "opened_security_key"), \
                mock.patch.object(enrollment.fido2_luks, "enroll", side_effect=SignInError("no")):
            with self.assertRaises(SignInError):
                task.run()
        self.assertNotIn("1234", repr(vars(task)))


if __name__ == "__main__":
    unittest.main()
