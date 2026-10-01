from enum import Enum

from pykickstart.constants import AUTOPART_TYPE_BTRFS

from pyanaconda.core.constants import PARTITIONING_METHOD_AUTOMATIC
from pyanaconda.modules.common.structures.partitioning import PartitioningRequest

__all__ = ["LUKS_VERSION", "StorageState", "with_encryption", "classify"]

LUKS_VERSION = "luks2"


class StorageState(Enum):
    NO_DISK = "no_disk"
    NOT_APPLIED = "not_applied"
    NOT_AUTOMATIC = "not_automatic"
    MISMATCH = "mismatch"
    MATCH = "match"


def with_encryption(request, password):
    encrypted = PartitioningRequest.from_structure(PartitioningRequest.to_structure(request))
    encrypted.partitioning_scheme = AUTOPART_TYPE_BTRFS
    encrypted.encrypted = True
    encrypted.luks_version = LUKS_VERSION
    encrypted.passphrase = password
    return encrypted


def classify(method, request, mounts_encrypted, password_matches, has_disks):
    if not has_disks:
        return StorageState.NO_DISK
    if not method:
        return StorageState.NOT_APPLIED
    if method != PARTITIONING_METHOD_AUTOMATIC:
        return StorageState.NOT_AUTOMATIC
    requested = (
        request.partitioning_scheme == AUTOPART_TYPE_BTRFS
        and request.encrypted
        and request.luks_version == LUKS_VERSION
        and password_matches(request.passphrase)
    )
    if requested and mounts_encrypted:
        return StorageState.MATCH
    return StorageState.MISMATCH
