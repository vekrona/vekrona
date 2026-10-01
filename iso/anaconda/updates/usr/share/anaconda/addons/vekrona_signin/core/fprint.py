import datetime
from dataclasses import dataclass, field
from pathlib import Path

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.errors import SignInError

__all__ = ["FINGERS", "EnrolledPrint", "list_readers", "find_reader", "enroll", "storage_path"]

FINGERS = {
    "left-thumb": 1,
    "left-index-finger": 2,
    "left-middle-finger": 3,
    "left-ring-finger": 4,
    "left-little-finger": 5,
    "right-thumb": 6,
    "right-index-finger": 7,
    "right-middle-finger": 8,
    "right-ring-finger": 9,
    "right-little-finger": 10,
}

FPRINT_STORAGE = Path("var/lib/fprint")


@dataclass(frozen=True)
class EnrolledPrint:
    driver: str
    device_id: str
    finger: int
    data: bytes = field(repr=False)


def storage_path(root, username, driver, device_id, finger):
    return Path(root) / FPRINT_STORAGE / username / driver / device_id / format(finger, "x")


def _fprint():
    import gi
    gi.require_version("FPrint", "2.0")
    from gi.repository import FPrint
    return FPrint


def list_readers():
    return [
        DeviceDescription.create(device.get_device_id(), device.get_name())
        for device in _fprint().Context().get_devices()
    ]


def find_reader(devices, device_id):
    for device in devices:
        if device.get_device_id() == device_id:
            return device
    raise SignInError("The fingerprint reader was unplugged; press Refresh")


def enroll(device_id, finger_nick, username, announce_scan):
    from gi.repository import GLib

    if finger_nick not in FINGERS:
        raise SignInError(f"Unknown finger: {finger_nick}")
    FPrint = _fprint()
    finger = FINGERS[finger_nick]
    device = find_reader(FPrint.Context().get_devices(), device_id)
    stages = device.get_nr_enroll_stages()

    def on_progress(_device, completed_stages, _print, _user_data, error):
        if error is not None:
            announce_scan(completed_stages + 1, stages, error.message)
        elif completed_stages < stages:
            announce_scan(completed_stages + 1, stages, None)

    today = datetime.date.today()
    template = FPrint.Print.new(device)
    template.set_finger(FPrint.Finger(finger))
    template.set_username(username)
    template.set_enroll_date(GLib.Date.new_dmy(today.day, today.month, today.year))

    device.open_sync()
    try:
        announce_scan(1, stages, None)
        enrolled = device.enroll_sync(template, None, on_progress, None)
        data = bytes(enrolled.serialize())
        return EnrolledPrint(
            driver=device.get_driver(),
            device_id=device.get_device_id(),
            finger=finger,
            data=data,
        )
    finally:
        device.close_sync()
