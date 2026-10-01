from pathlib import Path

from pyanaconda.anaconda_loggers import get_module_logger
from pyanaconda.core import util
from pyanaconda.modules.common.constants.objects import DEVICE_TREE
from pyanaconda.modules.common.constants.services import STORAGE
from pyanaconda.modules.common.structures.storage import DeviceData, DeviceFormatData
from pyanaconda.modules.common.task import Task

from vekrona_signin.core import luks
from vekrona_signin.core.crypttab import (
    LuksDevice,
    enable_fido2_unlock,
    require_fido2_unlock_support,
)
from vekrona_signin.core.encrypted_storage import applied_request
from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.fprint import storage_path
from vekrona_signin.core.passwd import parse_account
from vekrona_signin.core.private_files import write_private_file

log = get_module_logger(__name__)

__all__ = ["LuksFido2Task", "U2fKeysTask", "FprintTask"]

LUKS_FORMAT_TYPE = "luks"
U2F_KEYS_RELATIVE_PATH = Path(".config/Yubico/u2f_keys")


def find_luks_backing_paths(device_tree):
    mount_points = device_tree.GetMountPoints()
    ancestor_ids = device_tree.GetAncestors(sorted(set(mount_points.values())))
    chosen = {}
    skipped = []
    for device_id in device_tree.GetDevices():
        format_type = DeviceFormatData.from_structure(device_tree.GetFormatData(device_id)).type
        if format_type != LUKS_FORMAT_TYPE:
            continue
        path = DeviceData.from_structure(device_tree.GetDeviceData(device_id)).path
        if device_id in ancestor_ids:
            chosen[device_id] = path
        else:
            skipped.append(path)
    log.info("LUKS devices backing the installed system: %s", sorted(chosen.values()))
    log.info("LUKS devices left untouched: %s", sorted(skipped))
    if not chosen:
        raise SignInError("No LUKS device backing the installed system was found.")
    return sorted(chosen.values())


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

    def __init__(self, sysroot, enrollment):
        super().__init__()
        self._sysroot = sysroot
        self._enrollment = enrollment

    @property
    def name(self):
        return "Enroll the security key for disk unlocking"

    def run(self):
        require_fido2_unlock_support(self._sysroot)
        passphrase = find_luks_passphrase(STORAGE.get_proxy(), STORAGE.get_proxy)
        enrolled = []
        for device_path in find_luks_backing_paths(STORAGE.get_proxy(DEVICE_TREE)):
            luks.add_fido2_keyslot(device_path, passphrase, self._enrollment)
            log.info("Security key enrolled on %s.", device_path)
            enrolled.append(LuksDevice(device_path, luks.luks_uuid(device_path)))
        enable_fido2_unlock(self._sysroot, enrolled)
        log.info("The first boot unlocks %s with the security key.", [d.path for d in enrolled])


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
