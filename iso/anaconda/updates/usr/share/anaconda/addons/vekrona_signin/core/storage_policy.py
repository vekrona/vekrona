from enum import Enum

from pykickstart.constants import AUTOPART_TYPE_BTRFS

from pyanaconda.core.constants import PARTITIONING_METHOD_AUTOMATIC
from pyanaconda.modules.common.structures.partitioning import PartitioningRequest

__all__ = ["LUKS_VERSION", "StorageState", "with_encryption", "classify"]

LUKS_VERSION = "luks2"


class StorageState(Enum):
    NO_DISK = "no_disk"
    NOT_APPLIED = "not_applied"
    MANUAL_PLAIN = "manual_plain"
    MANUAL_LUKS = "manual_luks"
    MISMATCH = "mismatch"
    FOREIGN_PASSPHRASE = "foreign_passphrase"
    MATCH = "match"

    @property
    def needs_encryption(self):
        return self in (StorageState.MISMATCH, StorageState.FOREIGN_PASSPHRASE)

    @property
    def disk_chosen(self):
        return self not in (StorageState.NO_DISK, StorageState.NOT_APPLIED)

    @property
    def settled(self):
        return self in (StorageState.MATCH, StorageState.MANUAL_PLAIN, StorageState.MANUAL_LUKS)


def with_encryption(request, password):
    encrypted = PartitioningRequest.from_structure(PartitioningRequest.to_structure(request))
    encrypted.partitioning_scheme = AUTOPART_TYPE_BTRFS
    encrypted.encrypted = True
    encrypted.luks_version = LUKS_VERSION
    encrypted.passphrase = password
    return encrypted


def classify(method, request, *, mounts_encrypted, has_luks, password_matches, has_disks):
    if not has_disks:
        return StorageState.NO_DISK
    if not method:
        return StorageState.NOT_APPLIED
    if method != PARTITIONING_METHOD_AUTOMATIC:
        return StorageState.MANUAL_LUKS if has_luks else StorageState.MANUAL_PLAIN
    if request.encrypted and not password_matches(request.passphrase):
        return StorageState.FOREIGN_PASSPHRASE
    requested = (
        request.partitioning_scheme == AUTOPART_TYPE_BTRFS
        and request.encrypted
        and request.luks_version == LUKS_VERSION
        and password_matches(request.passphrase)
    )
    if requested and mounts_encrypted:
        return StorageState.MATCH
    return StorageState.MISMATCH
