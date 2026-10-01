from dasbus.server.interface import dbus_interface
from dasbus.typing import *  # pylint: disable=wildcard-import

from pyanaconda.modules.common.base import KickstartModuleInterface
from pyanaconda.modules.common.containers import TaskContainer
from vekrona_signin.constants import VEKRONA_SIGNIN
from vekrona_signin.core.device_scan import DeviceScan

__all__ = ["VekronaSignInInterface"]


@dbus_interface(VEKRONA_SIGNIN.interface_name)
class VekronaSignInInterface(KickstartModuleInterface):
    """The DBus interface of the vekrona sign-in service.

    Salts, credentials and prints never cross this interface; the spoke only learns
    whether a registration exists. The one secret that does cross it, the disk passphrase
    of a manual layout, only travels towards the service and is never read back.
    """

    def connect_signals(self):
        super().connect_signals()
        self.watch_property("SecurityKeyRegistered", self.implementation.security_key_registered_changed)
        self.watch_property("FingerprintEnrolled", self.implementation.fingerprint_enrolled_changed)

    @property
    def SecurityKeyRegistered(self) -> Bool:
        return self.implementation.security_key_registered

    @property
    def FingerprintEnrolled(self) -> Bool:
        return self.implementation.fingerprint_enrolled

    def ScanSecurityKeys(self) -> Structure:
        return DeviceScan.to_structure(self.implementation.scan_security_keys())

    def SecurityKeyHasPin(self, device_id: Str) -> Bool:
        return self.implementation.security_key_has_pin(device_id)

    def RegisterSecurityKeyWithTask(self, device_id: Str, pin: Str, set_pin: Bool) -> ObjPath:
        return TaskContainer.to_object_path(
            self.implementation.register_security_key_with_task(device_id, pin, set_pin)
        )

    def ScanFingerprintReaders(self) -> Structure:
        return DeviceScan.to_structure(self.implementation.scan_fingerprint_readers())

    def SetDiskPassphrase(self, passphrase: Str):
        self.implementation.set_disk_passphrase(passphrase)

    def ForgetIfUserChanged(self, username: Str) -> Bool:
        return self.implementation.forget_if_user_changed(username)

    def EnrollFingerWithTask(self, device_id: Str, finger: Str) -> ObjPath:
        return TaskContainer.to_object_path(
            self.implementation.enroll_finger_with_task(device_id, finger)
        )

    def ForgetSecurityKey(self):
        self.implementation.forget_security_key()

    def ForgetFingerprint(self):
        self.implementation.forget_fingerprint()
