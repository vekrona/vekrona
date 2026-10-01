import unittest

import _paths

from pykickstart.constants import AUTOPART_TYPE_BTRFS, AUTOPART_TYPE_LVM

from pyanaconda.modules.common.structures.partitioning import PartitioningRequest

from vekrona_signin.core.storage_policy import StorageState, classify, with_encryption

PASSWORD = "correct horse"


def matching_request():
    return with_encryption(PartitioningRequest(), PASSWORD)


def classified(request=None, *, method="AUTOMATIC", mounts_encrypted=True, has_luks=False, has_disks=True,
               password=PASSWORD):
    return classify(
        method,
        matching_request() if request is None else request,
        mounts_encrypted=mounts_encrypted,
        has_luks=has_luks,
        password_matches=lambda candidate: candidate == password,
        has_disks=has_disks,
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


class StorageStateTest(unittest.TestCase):
    def test_a_disk_is_chosen_once_a_partitioning_is_applied(self):
        unchosen = {StorageState.NO_DISK, StorageState.NOT_APPLIED}
        for state in StorageState:
            with self.subTest(state):
                self.assertIs(state.disk_chosen, state not in unchosen)

    def test_only_matching_and_manual_layouts_are_settled(self):
        settled = {StorageState.MATCH, StorageState.MANUAL_PLAIN, StorageState.MANUAL_LUKS}
        for state in StorageState:
            with self.subTest(state):
                self.assertIs(state.settled, state in settled)


class ClassifyTest(unittest.TestCase):
    def test_everything_in_place_matches(self):
        self.assertEqual(classified(), StorageState.MATCH)

    def test_no_disk_wins_over_everything(self):
        self.assertEqual(classified(has_disks=False, method=None), StorageState.NO_DISK)

    def test_missing_applied_partitioning(self):
        self.assertEqual(classified(method=None), StorageState.NOT_APPLIED)

    def test_manual_layouts_are_taken_as_they_are(self):
        for method in ("INTERACTIVE", "BLIVET", "CUSTOM", "MANUAL"):
            with self.subTest(method):
                self.assertEqual(classified(None, method=method), StorageState.MANUAL_PLAIN)
                self.assertEqual(classified(None, method=method, has_luks=True), StorageState.MANUAL_LUKS)

    def test_manual_layout_ignores_the_password_and_the_automatic_requirements(self):
        self.assertEqual(
            classified(None, method="INTERACTIVE", mounts_encrypted=False, password="other"),
            StorageState.MANUAL_PLAIN,
        )

    def test_manual_layout_without_a_disk_is_no_disk(self):
        self.assertEqual(classified(None, method="INTERACTIVE", has_disks=False), StorageState.NO_DISK)

    def test_encrypted_with_another_passphrase(self):
        self.assertEqual(classified(password="other"), StorageState.FOREIGN_PASSPHRASE)

    def test_only_unmatched_automatic_layouts_need_encryption(self):
        for state in StorageState:
            with self.subTest(state):
                self.assertIs(
                    state.needs_encryption, state in (StorageState.MISMATCH, StorageState.FOREIGN_PASSPHRASE)
                )

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
