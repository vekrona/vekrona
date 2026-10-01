from pathlib import Path

from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core import util
from pyanaconda.core.constants import PARTITIONING_METHOD_AUTOMATIC
from pyanaconda.modules.common.constants.objects import DEVICE_TREE
from pyanaconda.modules.common.constants.services import STORAGE
from pyanaconda.modules.common.task import Task

from vekrona_signin.core import luks
from vekrona_signin.core.crypttab import (
    LuksDevice,
    enable_fido2_unlock,
    require_fido2_unlock_support,
)
from vekrona_signin.core.encrypted_storage import applied_partitioning, applied_request
from vekrona_signin.core.errors import PassphraseRejected, SignInError
from vekrona_signin.core.fprint import storage_path
from vekrona_signin.core.luks_layout import read_luks_layout
from vekrona_signin.core.passwd import parse_account
from vekrona_signin.core.private_files import write_private_file

log = get_module_logger(__name__)

__all__ = ["LuksFido2Task", "U2fKeysTask", "FprintTask"]

U2F_KEYS_RELATIVE_PATH = Path(".config/Yubico/u2f_keys")


def find_luks_backing_paths(device_tree):
    layout = read_luks_layout(device_tree)
    log.info("LUKS devices backing the installed system: %s", list(layout.backing))
    log.info("LUKS devices left untouched: %s", list(layout.untouched))
    if not layout.backing:
        raise SignInError("No LUKS device backing the installed system was found.")
    return list(layout.backing)


def find_luks_passphrase(storage, get_partitioning_proxy):
    request = applied_request(storage, get_partitioning_proxy)
    if not request.encrypted:
        raise SignInError("The applied partitioning is not encrypted.")
    if not request.passphrase:
        raise SignInError("The applied partitioning has no LUKS passphrase.")
    return request.passphrase


def _restore_selinux_contexts(sysroot, path):
    returncode = util.execWithRedirect("restorecon", ["-R", str(path)], root=sysroot)
    if returncode != 0:
        raise SignInError(f"restorecon failed on {path} ({returncode}).")


def _target_account(sysroot, username):
    return parse_account((Path(sysroot) / "etc/passwd").read_text(), username)


class LuksFido2Task(Task):
    """Add the registered security key to the LUKS devices backing the installed system and make the first boot use it."""

    def __init__(self, sysroot, enrollment, manual_passphrase):
        super().__init__()
        self._sysroot = sysroot
        self._enrollment = enrollment
        self._manual_passphrase = manual_passphrase

    @property
    def name(self):
        return "Enroll the security key for disk unlocking"

    def run(self):
        try:
            self._enroll()
        finally:
            self._manual_passphrase = None

    def _enroll(self):
        automatic = (
            applied_partitioning(STORAGE.get_proxy(), STORAGE.get_proxy).PartitioningMethod
            == PARTITIONING_METHOD_AUTOMATIC
        )
        if automatic:
            device_paths = find_luks_backing_paths(STORAGE.get_proxy(DEVICE_TREE))
            passphrase = find_luks_passphrase(STORAGE.get_proxy(), STORAGE.get_proxy)
        else:
            device_paths = list(read_luks_layout(STORAGE.get_proxy(DEVICE_TREE)).backing)
            if not device_paths:
                log.info("The manual disk layout has no LUKS device; the security key does not unlock the disk.")
                return
            passphrase = self._require_manual_passphrase()
        require_fido2_unlock_support(self._sysroot)
        self._check_devices(device_paths, passphrase, automatic)
        enrolled = []
        for device_path in device_paths:
            luks.add_fido2_keyslot(device_path, passphrase, self._enrollment)
            log.info("Security key enrolled on %s.", device_path)
            enrolled.append(LuksDevice(device_path, luks.luks_uuid(device_path)))
        enable_fido2_unlock(self._sysroot, enrolled)
        log.info("The first boot unlocks %s with the security key.", [d.path for d in enrolled])

    def _require_manual_passphrase(self):
        if not self._manual_passphrase:
            raise SignInError(
                "The disk is encrypted with a passphrase chosen during partitioning, "
                "but it was not entered on VEKRONA SIGN-IN, so the security key cannot be added to it."
            )
        return self._manual_passphrase

    def _check_devices(self, device_paths, passphrase, automatic):
        for device_path in device_paths:
            luks.require_luks2(device_path)
        if automatic:
            return
        for device_path in device_paths:
            try:
                luks.verify_passphrase(device_path, passphrase)
            except PassphraseRejected as error:
                raise SignInError(
                    f"The disk passphrase entered on VEKRONA SIGN-IN did not unlock {device_path}. "
                    "It must be the passphrase chosen during partitioning."
                ) from error


class U2fKeysTask(Task):
    """Write the user's pam_u2f registration."""

    def __init__(self, sysroot, username, line):
        super().__init__()
        self._sysroot = sysroot
        self._username = username
        self._line = line

    @property
    def name(self):
        return "Register the security key for sign-in"

    def run(self):
        account = _target_account(self._sysroot, self._username)
        home = Path(self._sysroot) / account.home.lstrip("/")
        if not home.is_dir():
            raise SignInError(f"The home directory of {self._username} does not exist.")
        write_private_file(
            home, home / U2F_KEYS_RELATIVE_PATH, f"{self._line}\n".encode(), account.uid, account.gid
        )
        _restore_selinux_contexts(self._sysroot, Path("/") / account.home.lstrip("/") / ".config")
        log.info("Security key registered for %s.", self._username)


class FprintTask(Task):
    """Write the enrolled fingerprint in fprintd's storage."""

    def __init__(self, sysroot, username, enrolled_print):
        super().__init__()
        self._sysroot = sysroot
        self._username = username
        self._print = enrolled_print

    @property
    def name(self):
        return "Store the enrolled fingerprint"

    def run(self):
        path = storage_path(
            self._sysroot,
            self._username,
            self._print.driver,
            self._print.device_id,
            self._print.finger,
        )
        write_private_file(Path(self._sysroot) / "var/lib", path, self._print.data, 0, 0)
        _restore_selinux_contexts(self._sysroot, Path("/var/lib/fprint"))
        log.info("Fingerprint stored for %s.", self._username)
