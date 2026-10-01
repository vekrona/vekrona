from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core.configuration.anaconda import conf
from pyanaconda.core.dbus import DBus
from pyanaconda.core.signal import Signal
from pyanaconda.modules.common.base import KickstartService
from pyanaconda.modules.common.constants.services import USERS
from pyanaconda.modules.common.containers import TaskContainer
from pyanaconda.modules.common.structures.user import UserData

from vekrona_signin.constants import VEKRONA_SIGNIN
from vekrona_signin.core import fprint
from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.security_key import key_has_pin, list_security_keys, opened_security_key
from vekrona_signin.service.enrollment import (
    FingerprintEnrollmentTask,
    SecurityKeyRegistrationTask,
)
from vekrona_signin.service.installation import FprintTask, LuksFido2Task, U2fKeysTask
from vekrona_signin.service.kickstart import VekronaSignInKickstartSpecification
from vekrona_signin.service.vekrona_signin_interface import VekronaSignInInterface

log = get_module_logger(__name__)

__all__ = ["VekronaSignInService"]


class VekronaSignInService(KickstartService):
    """The implementation of the vekrona sign-in service."""

    def __init__(self):
        super().__init__()
        self._security_key = None
        self.security_key_registered_changed = Signal()
        self._fingerprint = None
        self.fingerprint_enrolled_changed = Signal()

    def publish(self):
        TaskContainer.set_namespace(VEKRONA_SIGNIN.namespace)
        DBus.publish_object(VEKRONA_SIGNIN.object_path, VekronaSignInInterface(self))
        DBus.register_service(VEKRONA_SIGNIN.service_name)

    @property
    def kickstart_specification(self):
        return VekronaSignInKickstartSpecification

    @property
    def security_key_registered(self):
        return self._security_key is not None

    @property
    def fingerprint_enrolled(self):
        return self._fingerprint is not None

    def _username(self):
        for user in UserData.from_structure_list(USERS.get_proxy().Users):
            if "wheel" in user.groups:
                return user.name
        raise SignInError("Create the user account first; sign-in methods are registered for it.")

    def list_security_keys(self):
        return list_security_keys()

    def security_key_has_pin(self, device_id):
        with opened_security_key(device_id) as device:
            return key_has_pin(device)

    def register_security_key_with_task(self, device_id, pin, set_pin):
        task = SecurityKeyRegistrationTask(device_id, pin, set_pin, self._username())
        task.succeeded_signal.connect(lambda: self._store_security_key(task.registration))
        return task

    def _store_security_key(self, registration):
        self._security_key = registration
        self.security_key_registered_changed.emit()

    def forget_security_key(self):
        self._security_key = None
        self.security_key_registered_changed.emit()

    def list_fingerprint_readers(self):
        return fprint.list_readers()

    def enroll_finger_with_task(self, device_id, finger):
        task = FingerprintEnrollmentTask(device_id, finger, self._username())
        task.succeeded_signal.connect(
            lambda: self._store_fingerprint(task.username, task.enrolled_print)
        )
        return task

    def _store_fingerprint(self, username, enrolled_print):
        self._fingerprint = (username, enrolled_print)
        self.fingerprint_enrolled_changed.emit()

    def forget_fingerprint(self):
        self._fingerprint = None
        self.fingerprint_enrolled_changed.emit()

    def install_with_tasks(self):
        sysroot = conf.target.system_root
        tasks = []
        if self._security_key is not None:
            self._require_registered_user(self._security_key.username)
            tasks.append(LuksFido2Task(self._security_key.luks_enrollment))
            tasks.append(U2fKeysTask(sysroot, self._security_key.username, self._security_key.u2f_line))
        if self._fingerprint is not None:
            username, enrolled_print = self._fingerprint
            self._require_registered_user(username)
            tasks.append(FprintTask(sysroot, username, enrolled_print))
        return tasks

    def _require_registered_user(self, registered_username):
        if self._username() != registered_username:
            raise SignInError(
                f"The user was renamed after registering a sign-in method for {registered_username}; "
                "register it again."
            )
