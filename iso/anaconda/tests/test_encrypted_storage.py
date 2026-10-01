import logging
import unittest
from unittest import mock

import _paths

from pykickstart.constants import AUTOPART_TYPE_BTRFS, AUTOPART_TYPE_LVM

from pyanaconda.modules.common.structures.partitioning import PartitioningRequest
from pyanaconda.modules.common.structures.storage import DeviceFormatData
from pyanaconda.modules.common.structures.validation import ValidationReport

from vekrona_signin.core.encrypted_storage import apply_encrypted, read_state
from vekrona_signin.core.storage_policy import StorageState, with_encryption

PASSWORD = "correct horse"
APPLIED = "/p/applied"
NEWER = "/p/newer"


class FakePartitioning:
    def __init__(self, method="AUTOMATIC", request=None):
        self.PartitioningMethod = method
        self.Request = PartitioningRequest.to_structure(request or PartitioningRequest())

    def request(self):
        return PartitioningRequest.from_structure(self.Request)


class FakeStorage:
    def __init__(self, applied="", created=()):
        self.AppliedPartitioning = applied
        self.CreatedPartitioning = list(created)


class FakeDiskSelection:
    def __init__(self, disks=("vda",)):
        self.SelectedDisks = list(disks)


class FakeDeviceTree:
    def __init__(self, formats, parents, mount_points):
        self._formats = formats
        self._parents = parents
        self._mount_points = mount_points

    def GetMountPoints(self):
        return dict(self._mount_points)

    def GetAncestors(self, device_ids):
        ancestors = set()
        pending = list(device_ids)
        while pending:
            for parent in self._parents.get(pending.pop(), []):
                ancestors.add(parent)
                pending.append(parent)
        return sorted(ancestors)

    def GetFormatData(self, device_id):
        data = DeviceFormatData()
        data.type = self._formats[device_id]
        return DeviceFormatData.to_structure(data)


def encrypted_tree():
    formats = {
        "vda": "disklabel", "vda1": "efi", "vda2": "ext4", "vda3": "luks",
        "root": "btrfs", "home": "btrfs",
    }
    parents = {
        "vda1": ["vda"], "vda2": ["vda"], "vda3": ["vda"],
        "root": ["vda3"], "home": ["vda3"],
    }
    mounts = {"/": "root", "/home": "home", "/boot": "vda2", "/boot/efi": "vda1"}
    return FakeDeviceTree(formats, parents, mounts)


def state(partitionings, tree, *, applied=APPLIED, created=(APPLIED,), disks=("vda",),
          password=PASSWORD, wait_until_idle=lambda: None):
    return read_state(
        lambda candidate: candidate == password,
        wait_until_idle=wait_until_idle,
        storage=FakeStorage(applied, created),
        get_partitioning_proxy=partitionings.__getitem__,
        device_tree=tree,
        disk_selection=FakeDiskSelection(disks),
    )


def matching_partitioning():
    return FakePartitioning(request=with_encryption(PartitioningRequest(), PASSWORD))


class RecordingDeviceTree(FakeDeviceTree):
    def __init__(self, events, *args):
        super().__init__(*args)
        self._events = events

    def GetMountPoints(self):
        self._events.append("device tree read")
        return super().GetMountPoints()


class ReadStateTest(unittest.TestCase):
    def test_device_tree_is_read_only_after_the_storage_is_idle(self):
        events = []
        reference = encrypted_tree()
        tree = RecordingDeviceTree(
            events, reference._formats, reference._parents, reference._mount_points
        )
        state(
            {APPLIED: matching_partitioning()},
            tree,
            wait_until_idle=lambda: events.append("storage idle"),
        )
        self.assertEqual(events[0], "storage idle")
        self.assertIn("device tree read", events)

    def test_encrypted_layout_with_the_password_matches(self):
        self.assertEqual(state({APPLIED: matching_partitioning()}, encrypted_tree()),
                         StorageState.MATCH)

    def test_wrong_password_is_a_mismatch(self):
        self.assertEqual(state({APPLIED: matching_partitioning()}, encrypted_tree(), password="x"),
                         StorageState.MISMATCH)

    def test_request_that_is_not_encrypted_is_a_mismatch(self):
        partitioning = FakePartitioning()
        self.assertEqual(state({APPLIED: partitioning}, encrypted_tree()), StorageState.MISMATCH)

    def test_wrong_luks_version_is_a_mismatch(self):
        for version in ("luks1", ""):
            request = with_encryption(PartitioningRequest(), PASSWORD)
            request.luks_version = version
            partitionings = {APPLIED: FakePartitioning(request=request)}
            self.assertEqual(state(partitionings, encrypted_tree()), StorageState.MISMATCH, version)

    def test_lvm_scheme_is_a_mismatch(self):
        request = with_encryption(PartitioningRequest(), PASSWORD)
        request.partitioning_scheme = AUTOPART_TYPE_LVM
        partitionings = {APPLIED: FakePartitioning(request=request)}
        self.assertEqual(state(partitionings, encrypted_tree()), StorageState.MISMATCH)

    def test_non_automatic_applied_partitioning(self):
        partitionings = {APPLIED: FakePartitioning(method="CUSTOM")}
        self.assertEqual(state(partitionings, encrypted_tree()), StorageState.NOT_AUTOMATIC)

    def test_nothing_applied(self):
        self.assertEqual(state({}, encrypted_tree(), applied=""), StorageState.NOT_APPLIED)

    def test_no_selected_disk(self):
        self.assertEqual(state({APPLIED: matching_partitioning()}, encrypted_tree(), disks=()),
                         StorageState.NO_DISK)

    def test_request_claiming_encryption_over_a_plain_root_is_a_mismatch(self):
        tree = encrypted_tree()
        tree._parents["root"] = ["vda2"]
        self.assertEqual(state({APPLIED: matching_partitioning()}, tree), StorageState.MISMATCH)

    def test_system_mount_point_outside_luks_on_a_second_disk_is_a_mismatch(self):
        tree = encrypted_tree()
        tree._formats.update({"vdb": "disklabel", "vdb1": "ext4"})
        tree._parents["vdb1"] = ["vdb"]
        tree._mount_points["/data"] = "vdb1"
        self.assertEqual(state({APPLIED: matching_partitioning()}, tree), StorageState.MISMATCH)

    def test_root_that_is_not_btrfs_is_a_mismatch(self):
        tree = encrypted_tree()
        tree._formats["root"] = "ext4"
        self.assertEqual(state({APPLIED: matching_partitioning()}, tree), StorageState.MISMATCH)

    def test_newer_unapplied_matching_module_does_not_count(self):
        partitionings = {APPLIED: FakePartitioning(), NEWER: matching_partitioning()}
        result = state(partitionings, encrypted_tree(), created=(APPLIED, NEWER))
        self.assertEqual(result, StorageState.MISMATCH)


def valid_report():
    return ValidationReport()


def invalid_report():
    report = ValidationReport()
    report.error_messages.append("not enough space")
    return report


class FakeDiskInitialization:
    def __init__(self):
        self.InitializationMode = -1
        self.InitializeLabelsEnabled = False


class ApplyEncryptedTest(unittest.TestCase):
    def apply(self, partitionings, *, storage=None, disks=("vda",), apply=None):
        created = []
        calls = mock.Mock()
        calls.create.side_effect = lambda method: created.append(FakePartitioning(method)) or created[-1]
        calls.apply.side_effect = apply or (lambda *_: valid_report())
        disk_initialization = FakeDiskInitialization()
        report, applied = apply_encrypted(
            PASSWORD,
            show_message=calls.show,
            reset_storage_cb=calls.reset,
            storage=storage or FakeStorage(APPLIED, [APPLIED]),
            get_partitioning_proxy=partitionings.__getitem__,
            disk_selection=FakeDiskSelection(disks),
            disk_initialization=disk_initialization,
            create_partitioning=calls.create,
            apply=calls.apply,
        )
        self.assertIs(applied, created[0] if created else None)
        return report, calls, created, disk_initialization

    def stale(self):
        request = PartitioningRequest()
        request.partitioning_scheme = AUTOPART_TYPE_LVM
        request.excluded_mount_points = ["/home"]
        return FakePartitioning(request=request)

    def test_a_fresh_module_takes_the_applied_request_with_encryption(self):
        stale = self.stale()
        before = stale.Request
        report, calls, created, _ = self.apply({APPLIED: stale})
        self.assertTrue(report.is_valid())
        calls.create.assert_called_once_with("AUTOMATIC")
        request = created[0].request()
        self.assertEqual(request.partitioning_scheme, AUTOPART_TYPE_BTRFS)
        self.assertTrue(request.encrypted)
        self.assertEqual(request.luks_version, "luks2")
        self.assertEqual(request.passphrase, PASSWORD)
        self.assertEqual(request.excluded_mount_points, ["/home"])
        calls.apply.assert_called_once_with(created[0], calls.show, calls.reset)
        self.assertEqual(stale.Request, before)

    def test_disks_are_initialized_like_the_stock_spoke_does(self):
        _, _, _, disk_initialization = self.apply({APPLIED: self.stale()})
        self.assertEqual(disk_initialization.InitializationMode, 0)
        self.assertTrue(disk_initialization.InitializeLabelsEnabled)

    def test_without_any_partitioning_the_default_request_is_encrypted(self):
        report, calls, created, _ = self.apply({}, storage=FakeStorage("", []))
        calls.create.assert_called_once_with("AUTOMATIC")
        self.assertTrue(created[0].request().encrypted)
        self.assertEqual(created[0].request().passphrase, PASSWORD)
        self.assertTrue(report.is_valid())

    def test_last_created_automatic_request_is_the_base_when_nothing_is_applied(self):
        older = FakePartitioning()
        newer = self.stale()
        custom = FakePartitioning("CUSTOM")
        partitionings = {"/o": older, "/n": newer, "/c": custom}
        _, _, created, _ = self.apply(partitionings, storage=FakeStorage("", ["/o", "/n", "/c"]))
        self.assertEqual(created[0].request().excluded_mount_points, ["/home"])
        self.assertFalse(older.request().encrypted)
        self.assertFalse(newer.request().encrypted)

    def test_invalid_report_is_returned_and_existing_modules_stay_untouched(self):
        stale = self.stale()
        before = stale.Request
        report, _, _, _ = self.apply({APPLIED: stale}, apply=lambda *_: invalid_report())
        self.assertFalse(report.is_valid())
        self.assertEqual(stale.Request, before)

    def test_exception_propagates(self):
        def failing(*_):
            raise RuntimeError("boom")

        with self.assertRaisesRegex(RuntimeError, "boom"):
            self.apply({APPLIED: self.stale()}, apply=failing)

    def test_without_disks_nothing_is_created_or_applied(self):
        report, calls, _, disk_initialization = self.apply({APPLIED: self.stale()}, disks=())
        self.assertFalse(report.is_valid())
        calls.create.assert_not_called()
        calls.apply.assert_not_called()
        self.assertEqual(disk_initialization.InitializationMode, -1)

    def test_passphrase_is_never_logged(self):
        with self.assertLogs(level=logging.DEBUG) as captured:
            logging.getLogger("test").debug("anchor")
            self.apply({APPLIED: self.stale()}, apply=lambda *_: invalid_report())
        self.assertNotIn(PASSWORD, "\n".join(captured.output))


if __name__ == "__main__":
    unittest.main()
