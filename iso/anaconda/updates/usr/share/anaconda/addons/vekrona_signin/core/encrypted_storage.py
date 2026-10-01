from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core.constants import CLEAR_PARTITIONS_NONE, PARTITIONING_METHOD_AUTOMATIC
from pyanaconda.modules.common.structures.partitioning import PartitioningRequest
from pyanaconda.modules.common.structures.validation import ValidationReport

from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.luks_layout import LUKS_FORMAT_TYPE, format_type, read_luks_layout
from vekrona_signin.core.storage_policy import classify, with_encryption

log = get_module_logger(__name__)

__all__ = ["read_state", "applied_partitioning", "applied_request", "apply_encrypted"]

BTRFS_FORMAT_TYPE = "btrfs"
UNENCRYPTED_MOUNT_POINTS = ("/boot", "/boot/efi")
NO_DISK_MESSAGE = "No disk is selected for the installation."


def _is_behind_luks(device_tree, device_id):
    ancestors = device_tree.GetAncestors([device_id])
    return any(format_type(device_tree, ancestor) == LUKS_FORMAT_TYPE for ancestor in ancestors)


def _mounts_encrypted(device_tree):
    mount_points = device_tree.GetMountPoints()
    root_id = mount_points.get("/")
    if root_id is None or format_type(device_tree, root_id) != BTRFS_FORMAT_TYPE:
        return False
    system_ids = [
        device_id
        for mount_point, device_id in mount_points.items()
        if mount_point not in UNENCRYPTED_MOUNT_POINTS
    ]
    return all(_is_behind_luks(device_tree, device_id) for device_id in system_ids)


def read_state(password_matches, *, wait_until_idle, storage, get_partitioning_proxy, device_tree, disk_selection):
    wait_until_idle()
    has_disks = bool(disk_selection.SelectedDisks)
    object_path = storage.AppliedPartitioning
    if not has_disks or not object_path:
        return classify(
            None, None, mounts_encrypted=False, has_luks=False,
            password_matches=password_matches, has_disks=has_disks,
        )
    applied = get_partitioning_proxy(object_path)
    method = applied.PartitioningMethod
    automatic = method == PARTITIONING_METHOD_AUTOMATIC
    return classify(
        method,
        PartitioningRequest.from_structure(applied.Request) if automatic else None,
        mounts_encrypted=automatic and _mounts_encrypted(device_tree),
        has_luks=not automatic and bool(read_luks_layout(device_tree).backing),
        password_matches=password_matches,
        has_disks=has_disks,
    )


def applied_partitioning(storage, get_partitioning_proxy):
    object_path = storage.AppliedPartitioning
    if not object_path:
        raise SignInError("No partitioning has been applied.")
    return get_partitioning_proxy(object_path)


def applied_request(storage, get_partitioning_proxy):
    return PartitioningRequest.from_structure(applied_partitioning(storage, get_partitioning_proxy).Request)


def _applied_automatic_request(storage, get_partitioning_proxy):
    applied = applied_partitioning(storage, get_partitioning_proxy)
    if applied.PartitioningMethod != PARTITIONING_METHOD_AUTOMATIC:
        raise SignInError("The applied disk setup is not automatic; it is used as it is.")
    return PartitioningRequest.from_structure(applied.Request)


def apply_encrypted(
    password,
    *,
    show_message,
    reset_storage_cb,
    storage,
    get_partitioning_proxy,
    disk_selection,
    disk_initialization,
    create_partitioning,
    apply,
):
    if not disk_selection.SelectedDisks:
        report = ValidationReport()
        report.error_messages.append(NO_DISK_MESSAGE)
        log.warning(NO_DISK_MESSAGE)
        return report, None

    request = with_encryption(_applied_automatic_request(storage, get_partitioning_proxy), password)
    disk_initialization.InitializationMode = CLEAR_PARTITIONS_NONE
    disk_initialization.InitializeLabelsEnabled = True
    partitioning = create_partitioning(PARTITIONING_METHOD_AUTOMATIC)
    partitioning.Request = PartitioningRequest.to_structure(request)
    report = apply(partitioning, show_message, reset_storage_cb)
    if not report.is_valid():
        log.warning("The encrypted partitioning is not valid: %s", report.error_messages)
    return report, partitioning
