import unittest
from types import SimpleNamespace

import _paths

from pykickstart.constants import AUTOPART_TYPE_BTRFS, AUTOPART_TYPE_LVM

from pyanaconda.modules.common.structures.partitioning import PartitioningRequest

from vekrona_signin.gui.storage_link import find_storage_spoke, seed_storage_spoke


class FakeCheckbox:
    def __init__(self):
        self.active = False

    def set_active(self, value):
        self.active = value


def stock_spoke(checkbox):
    request = PartitioningRequest()
    request.partitioning_scheme = AUTOPART_TYPE_LVM
    request.excluded_mount_points = ["/home"]
    builder = SimpleNamespace(get_object=lambda name: checkbox if name == "encryptionCheckbox" else None)
    return SimpleNamespace(_partitioning_request=request, builder=builder)


def sign_in_spoke(spokes):
    return SimpleNamespace(main_window=SimpleNamespace(current_action=SimpleNamespace(_spokes=spokes)))


class SeedStorageSpokeTest(unittest.TestCase):
    def test_seeding_sets_the_request_and_ticks_the_checkbox(self):
        checkbox = FakeCheckbox()
        spoke = stock_spoke(checkbox)
        self.assertTrue(seed_storage_spoke(spoke, "secret"))
        request = spoke._partitioning_request
        self.assertTrue(request.encrypted)
        self.assertEqual(request.passphrase, "secret")
        self.assertEqual(request.partitioning_scheme, AUTOPART_TYPE_BTRFS)
        self.assertEqual(request.luks_version, "luks2")
        self.assertEqual(request.excluded_mount_points, ["/home"])
        self.assertTrue(checkbox.active)

    def test_missing_checkbox_is_reported(self):
        self.assertFalse(seed_storage_spoke(stock_spoke(None), "secret"))

    def test_missing_request_snapshot_is_reported(self):
        spoke = stock_spoke(FakeCheckbox())
        del spoke._partitioning_request
        self.assertFalse(seed_storage_spoke(spoke, "secret"))

    def test_missing_builder_is_reported(self):
        self.assertFalse(seed_storage_spoke(SimpleNamespace(_partitioning_request=PartitioningRequest()), "x"))


class FindStorageSpokeTest(unittest.TestCase):
    def test_stock_spoke_is_found_by_name(self):
        stock = object()
        self.assertIs(find_storage_spoke(sign_in_spoke({"StorageSpoke": stock})), stock)

    def test_missing_entry_gives_none(self):
        with self.assertLogs(level="WARNING"):
            self.assertIsNone(find_storage_spoke(sign_in_spoke({})))

    def test_missing_attributes_give_none(self):
        with self.assertLogs(level="WARNING"):
            self.assertIsNone(find_storage_spoke(SimpleNamespace()))
        with self.assertLogs(level="WARNING"):
            self.assertIsNone(find_storage_spoke(SimpleNamespace(main_window=SimpleNamespace())))


if __name__ == "__main__":
    unittest.main()
