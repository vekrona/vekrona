from contextlib import contextmanager

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.device_scan import DeviceScan, HintCode
from vekrona_signin.core.diagnose import (
    SYSFS_USB,
    describe_exception,
    hidraw_nodes,
    library_missing,
    usb_devices,
)
from vekrona_signin.core.errors import SignInError

__all__ = ["scan_security_keys", "find_descriptor", "opened_security_key", "key_has_pin"]


def _load_descriptor_reader():
    from fido2.hid.linux import get_descriptor

    return get_descriptor


def _read_descriptors(hidraw_paths, read_descriptor):
    descriptors = []
    problems = []
    for path in hidraw_paths:
        try:
            descriptors.append(read_descriptor(path))
        except ValueError:
            continue
        except Exception as error:
            problems.append((path, error))
    return descriptors, problems


def _describe(descriptor):
    return DeviceDescription.create(
        descriptor.path,
        f"{descriptor.product_name or 'Security key'} ({descriptor.vid:04x}:{descriptor.pid:04x})",
    )


def scan_security_keys(
    sysfs_root=SYSFS_USB, list_hidraw=hidraw_nodes, read_descriptor=None
):
    usb_seen = usb_devices(sysfs_root)
    try:
        read_descriptor = read_descriptor or _load_descriptor_reader()
    except ImportError as error:
        return library_missing("python3-fido2", error, usb_seen)
    hidraw_paths = list_hidraw()
    descriptors, problems = _read_descriptors(hidraw_paths, read_descriptor)
    devices = [_describe(descriptor) for descriptor in descriptors]
    problem = "; ".join(f"{path}: {describe_exception(error)}" for path, error in problems)
    if devices:
        hint = HintCode.OK
    elif any(isinstance(error, PermissionError) for _, error in problems):
        hint = HintCode.ACCESS_DENIED
    elif problems:
        hint = HintCode.DEVICE_UNUSABLE
    else:
        hint = HintCode.NO_DEVICE
    return DeviceScan.create(devices, problem, usb_seen, hint)


def find_descriptor(descriptors, device_id):
    for descriptor in descriptors:
        if descriptor.path == device_id:
            return descriptor
    raise SignInError("The security key was unplugged; press Check again")


@contextmanager
def opened_security_key(device_id):
    from fido2.hid import CtapHidDevice, open_connection

    descriptors, _ = _read_descriptors(hidraw_nodes(), _load_descriptor_reader())
    descriptor = find_descriptor(descriptors, device_id)
    device = CtapHidDevice(descriptor, open_connection(descriptor))
    try:
        yield device
    finally:
        device.close()


def key_has_pin(device):
    from fido2.ctap2 import Ctap2

    options = Ctap2(device).info.options
    if "clientPin" not in options:
        raise SignInError("This security key does not support a PIN.")
    return options["clientPin"]
