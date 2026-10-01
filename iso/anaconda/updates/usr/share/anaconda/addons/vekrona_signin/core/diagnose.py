import glob
from pathlib import Path

from vekrona_signin.core.device_scan import DeviceScan, HintCode

__all__ = ["SYSFS_USB", "usb_devices", "hidraw_nodes", "describe_exception", "library_missing"]

SYSFS_USB = Path("/sys/bus/usb/devices")
HUB_DEVICE_CLASS = "09"


def _attribute(directory, name):
    try:
        return (directory / name).read_text().strip()
    except FileNotFoundError:
        return ""


def usb_devices(sysfs_root=SYSFS_USB):
    seen = []
    for directory in sorted(Path(sysfs_root).iterdir()):
        vendor = _attribute(directory, "idVendor")
        product = _attribute(directory, "idProduct")
        if not vendor or not product:
            continue
        if _attribute(directory, "bDeviceClass") == HUB_DEVICE_CLASS:
            continue
        label = " ".join(
            part for part in (_attribute(directory, "manufacturer"), _attribute(directory, "product")) if part
        )
        seen.append(f"{vendor}:{product} {label}".rstrip())
    return seen


def hidraw_nodes(dev_root="/dev"):
    return sorted(glob.glob(f"{dev_root}/hidraw*"))


def describe_exception(error):
    return f"{type(error).__name__}: {error}"


def library_missing(library, error, usb_seen):
    return DeviceScan.create(
        [], f"{library} cannot be loaded. {describe_exception(error)}", usb_seen, HintCode.LIBRARY_MISSING
    )
