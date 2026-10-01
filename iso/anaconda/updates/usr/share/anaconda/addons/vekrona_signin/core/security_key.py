from contextlib import contextmanager

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.errors import SignInError

__all__ = ["list_security_keys", "find_descriptor", "opened_security_key", "key_has_pin"]


def list_security_keys():
    from fido2.hid import list_descriptors

    return [
        DeviceDescription.create(
            descriptor.path,
            f"{descriptor.product_name or 'Security key'} ({descriptor.vid:04x}:{descriptor.pid:04x})",
        )
        for descriptor in list_descriptors()
    ]


def find_descriptor(descriptors, device_id):
    for descriptor in descriptors:
        if descriptor.path == device_id:
            return descriptor
    raise SignInError("The security key was unplugged; press Refresh")


@contextmanager
def opened_security_key(device_id):
    from fido2.hid import CtapHidDevice, list_descriptors, open_connection

    descriptor = find_descriptor(list_descriptors(), device_id)
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
