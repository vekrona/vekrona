import unittest

import _paths

from pykickstart.constants import AUTOPART_TYPE_BTRFS, AUTOPART_TYPE_LVM

from pyanaconda.modules.common.structures.partitioning import PartitioningRequest

from vekrona_signin.core.storage_policy import StorageState, classify, with_encryption

PASSWORD = "correct horse"


def matching_request():
    return with_encryption(PartitioningRequest(), PASSWORD)


def classified(request=None, *, method="AUTOMATIC", mounts_encrypted=True, has_disks=True,
               password=PASSWORD):
    return classify(
        method,
        matching_request() if request is None else request,
        mounts_encrypted,
        lambda candidate: candidate == password,
        has_disks,
    )


class WithEncryptionTest(unittest.TestCase):
    def test_result_is_btrfs_luks2_with_the_passphrase(self):
        request = matching_request()
        self.assertEqual(request.partitioning_scheme, AUTOPART_TYPE_BTRFS)
        self.assertTrue(request.encrypted)
        self.assertEqual(request.luks_version, "luks2")
        self.assertEqual(request.passphrase, PASSWORD)

    def test_other_fields_are_preserved_and_the_input_is_untouched(self):
        original = PartitioningRequest()
        original.partitioning_scheme = AUTOPART_TYPE_LVM
        original.excluded_mount_points = ["/home"]
        original.hibernation = True
        result = with_encryption(original, PASSWORD)
        self.assertEqual(result.excluded_mount_points, ["/home"])
        self.assertTrue(result.hibernation)
        self.assertEqual(original.partitioning_scheme, AUTOPART_TYPE_LVM)
        self.assertFalse(original.encrypted)
        self.assertEqual(original.passphrase, "")


class ClassifyTest(unittest.TestCase):
    def test_everything_in_place_matches(self):
        self.assertEqual(classified(), StorageState.MATCH)

    def test_no_disk_wins_over_everything(self):
        self.assertEqual(classified(has_disks=False, method=None), StorageState.NO_DISK)

    def test_missing_applied_partitioning(self):
        self.assertEqual(classified(method=None), StorageState.NOT_APPLIED)

    def test_non_automatic_method(self):
        self.assertEqual(classified(method="CUSTOM"), StorageState.NOT_AUTOMATIC)

    def test_wrong_password(self):
        self.assertEqual(classified(password="other"), StorageState.MISMATCH)

    def test_unencrypted_request(self):
        request = matching_request()
        request.encrypted = False
        self.assertEqual(classified(request), StorageState.MISMATCH)

    def test_wrong_luks_version(self):
        for version in ("luks1", ""):
            request = matching_request()
            request.luks_version = version
            self.assertEqual(classified(request), StorageState.MISMATCH, version)

    def test_lvm_scheme(self):
        request = matching_request()
        request.partitioning_scheme = AUTOPART_TYPE_LVM
        self.assertEqual(classified(request), StorageState.MISMATCH)

    def test_device_tree_without_encryption(self):
        self.assertEqual(classified(mounts_encrypted=False), StorageState.MISMATCH)


if __name__ == "__main__":
    unittest.main()
