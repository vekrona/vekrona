from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.modules.common.task import Task

from vekrona_signin.core import fido2_luks, fprint, pam_u2f
from vekrona_signin.core.security_key import opened_security_key

log = get_module_logger(__name__)

__all__ = ["SecurityKeyRegistration", "SecurityKeyRegistrationTask", "FingerprintEnrollmentTask"]

TOUCHES = 3


class SecurityKeyRegistration:
    def __init__(self, username, luks_enrollment, u2f_line):
        self.username = username
        self.luks_enrollment = luks_enrollment
        self.u2f_line = u2f_line


class SecurityKeyRegistrationTask(Task):
    """Register a security key for disk unlocking and sign-in: three touches."""

    def __init__(self, device_id, pin, set_pin, username):
        super().__init__()
        self._device_id = device_id
        self._pin = pin
        self._set_pin = set_pin
        self._username = username
        self.registration = None
        self._touches_announced = 0

    @property
    def name(self):
        return "Register the security key"

    @property
    def steps(self):
        return TOUCHES

    def _announce_touch(self):
        self._touches_announced += 1
        self.report_progress(
            f"Touch your security key ({self._touches_announced}/{TOUCHES})",
            step_number=self._touches_announced - 1,
        )

    def run(self):
        try:
            with opened_security_key(self._device_id) as device:
                luks_enrollment = fido2_luks.enroll(
                    device, self._pin, self._set_pin, self._announce_touch
                )
                u2f_line = pam_u2f.register(
                    device, self._pin, self._username, self._announce_touch
                )
        finally:
            self._pin = None
        self.registration = SecurityKeyRegistration(self._username, luks_enrollment, u2f_line)
        log.info("Security key registered.")


class FingerprintEnrollmentTask(Task):
    """Enroll one finger on a fingerprint reader."""

    def __init__(self, device_id, finger, username):
        super().__init__()
        self._device_id = device_id
        self._finger = finger
        self.username = username
        self.enrolled_print = None

    @property
    def name(self):
        return "Enroll the fingerprint"

    def _announce_scan(self, stage, stages, retry_reason):
        message = f"Scan your finger ({stage}/{stages})"
        if retry_reason:
            message = f"{message}: {retry_reason}"
        self.report_progress(message)

    def run(self):
        self.enrolled_print = fprint.enroll(
            self._device_id, self._finger, self.username, self._announce_scan
        )
        log.info("Fingerprint enrolled.")
