from dasbus.structure import DBusData
from dasbus.typing import *  # pylint: disable=wildcard-import

from vekrona_signin.core.device_description import DeviceDescription

__all__ = ["DeviceScan", "HintCode"]


class HintCode:
    OK = "ok"
    NO_USB_DEVICE = "no_usb_device"
    USB_SEEN_BUT_UNUSABLE = "usb_seen_but_unusable"
    ACCESS_DENIED = "access_denied"
    LIBRARY_MISSING = "library_missing"


class DeviceScan(DBusData):
    """The outcome of looking for one kind of device, including why it found none."""

    def __init__(self):
        self._devices = []
        self._problem = ""
        self._usb_seen = []
        self._hint_code = HintCode.NO_USB_DEVICE

    @property
    def devices(self) -> List[Structure]:
        return DeviceDescription.to_structure_list(self._devices)

    @devices.setter
    def devices(self, value: List[Structure]):
        self._devices = DeviceDescription.from_structure_list(value)

    @property
    def problem(self) -> Str:
        return self._problem

    @problem.setter
    def problem(self, value: Str):
        self._problem = value

    @property
    def usb_seen(self) -> List[Str]:
        return self._usb_seen

    @usb_seen.setter
    def usb_seen(self, value: List[Str]):
        self._usb_seen = value

    @property
    def hint_code(self) -> Str:
        return self._hint_code

    @hint_code.setter
    def hint_code(self, value: Str):
        self._hint_code = value

    @classmethod
    def create(cls, devices, problem, usb_seen, hint_code):
        scan = cls()
        scan._devices = list(devices)
        scan.problem = problem
        scan.usb_seen = list(usb_seen)
        scan.hint_code = hint_code
        return scan
