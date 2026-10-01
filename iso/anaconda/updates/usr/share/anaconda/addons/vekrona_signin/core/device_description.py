from dasbus.structure import DBusData
from dasbus.typing import *  # pylint: disable=wildcard-import

__all__ = ["DeviceDescription"]


class DeviceDescription(DBusData):
    """A device the user can pick: a stable id and a name to show."""

    def __init__(self):
        self._id = ""
        self._name = ""

    @property
    def id(self) -> Str:
        return self._id

    @id.setter
    def id(self, value: Str):
        self._id = value

    @property
    def name(self) -> Str:
        return self._name

    @name.setter
    def name(self, value: Str):
        self._name = value

    @classmethod
    def create(cls, device_id, name):
        description = cls()
        description.id = device_id
        description.name = name
        return description
