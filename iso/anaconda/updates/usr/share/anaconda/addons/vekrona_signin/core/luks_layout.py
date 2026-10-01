from dataclasses import dataclass

from pyanaconda.modules.common.structures.storage import DeviceData, DeviceFormatData

__all__ = ["LUKS_FORMAT_TYPE", "LuksLayout", "format_type", "read_luks_layout"]

LUKS_FORMAT_TYPE = "luks"


@dataclass(frozen=True)
class LuksLayout:
    backing: tuple
    untouched: tuple


def format_type(device_tree, device_id):
    return DeviceFormatData.from_structure(device_tree.GetFormatData(device_id)).type


def read_luks_layout(device_tree):
    mount_points = device_tree.GetMountPoints()
    ancestor_ids = device_tree.GetAncestors(sorted(set(mount_points.values())))
    backing = []
    untouched = []
    for device_id in device_tree.GetDevices():
        if format_type(device_tree, device_id) != LUKS_FORMAT_TYPE:
            continue
        path = DeviceData.from_structure(device_tree.GetDeviceData(device_id)).path
        (backing if device_id in ancestor_ids else untouched).append(path)
    return LuksLayout(tuple(sorted(backing)), tuple(sorted(untouched)))
