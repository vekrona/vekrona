import glob
from dataclasses import dataclass
from pathlib import Path

from vekrona_signin.core.errors import SignInError

__all__ = ["LuksDevice", "enable_fido2_unlock", "require_fido2_unlock_support"]

FIDO2_OPTIONS = ("fido2-device=auto", "token-timeout=10s")
CRYPTTAB_RELATIVE_PATH = Path("etc/crypttab")
TOKEN_LIBRARY_PATTERN = "usr/lib*/cryptsetup/libcryptsetup-token-systemd-fido2.so"
LIBFIDO2_PATTERN = "usr/lib*/libfido2.so.*"
NO_OPTIONS = ("none", "-")


@dataclass(frozen=True)
class LuksDevice:
    path: str
    uuid: str

    def is_named_by(self, crypttab_device):
        return crypttab_device == self.path or crypttab_device.upper() == f"UUID={self.uuid}".upper()


def _merged_options(existing):
    merged = [] if existing in NO_OPTIONS else existing.split(",")
    present = {option.split("=", 1)[0] for option in merged}
    merged += [option for option in FIDO2_OPTIONS if option.split("=", 1)[0] not in present]
    return ",".join(merged)


def _entry_fields(line):
    fields = line.split()
    if len(fields) < 2 or fields[0].startswith("#"):
        return None
    name, crypttab_device, *rest = fields
    keyfile = rest[0] if rest else "none"
    options = rest[1] if len(rest) > 1 else "none"
    return name, crypttab_device, keyfile, options


def _with_fido2_option(line, devices):
    entry = _entry_fields(line)
    if entry is None:
        return line
    name, crypttab_device, keyfile, options = entry
    if not any(device.is_named_by(crypttab_device) for device in devices):
        return line
    return f"{name} {crypttab_device} {keyfile} {_merged_options(options)}"


def _enrolled_devices_without_entry(lines, devices):
    entries = [entry for entry in map(_entry_fields, lines) if entry is not None]
    return [
        device.path
        for device in devices
        if not any(device.is_named_by(entry[1]) for entry in entries)
    ]


def enable_fido2_unlock(sysroot, devices):
    crypttab = Path(sysroot) / CRYPTTAB_RELATIVE_PATH
    try:
        lines = crypttab.read_text().splitlines()
    except OSError as error:
        raise SignInError(f"Cannot read {crypttab}: {error}") from error
    missing = _enrolled_devices_without_entry(lines, devices)
    if missing:
        raise SignInError(f"{crypttab} has no entry for the enrolled LUKS device(s): {', '.join(missing)}.")
    rewritten = [_with_fido2_option(line, devices) for line in lines]
    try:
        crypttab.write_text("\n".join(rewritten) + "\n")
    except OSError as error:
        raise SignInError(f"Cannot write {crypttab}: {error}") from error


def require_fido2_unlock_support(sysroot):
    for what, pattern in (
        ("libcryptsetup-token-systemd-fido2.so (package systemd-udev)", TOKEN_LIBRARY_PATTERN),
        ("libfido2 (package libfido2)", LIBFIDO2_PATTERN),
    ):
        if not glob.glob(str(Path(sysroot) / pattern)):
            raise SignInError(f"The installed system lacks {what}; the initramfs could not unlock the disk with the key.")
