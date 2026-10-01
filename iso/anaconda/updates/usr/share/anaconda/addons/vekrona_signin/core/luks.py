import json
import os
from contextlib import contextmanager

from pyanaconda.core import util

from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.fido2_luks import passphrase, token_json

__all__ = ["parse_keyslot_numbers", "add_fido2_keyslot"]

CRYPTSETUP = "cryptsetup"
FAST_PBKDF = ["--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000"]


def parse_keyslot_numbers(dump_json_metadata):
    return {int(number) for number in json.loads(dump_json_metadata)["keyslots"]}


@contextmanager
def _in_memory_file(content):
    descriptor = os.memfd_create("vekrona-secret")
    try:
        os.write(descriptor, content)
        yield f"/proc/{os.getpid()}/fd/{descriptor}"
    finally:
        os.close(descriptor)


def _cryptsetup(arguments, secret_bearing):
    returncode, output = util.execProgram(
        CRYPTSETUP, arguments, log_output=not secret_bearing
    )
    if returncode != 0:
        raise SignInError(f"cryptsetup {arguments[0]} failed ({returncode}): {output.strip()}")
    return output


def _keyslot_numbers(device_path):
    return parse_keyslot_numbers(
        _cryptsetup(["luksDump", "--dump-json-metadata", device_path], secret_bearing=False)
    )


def _import_token_or_release_keyslot(device_path, keyslot, new_key, enrollment):
    with _in_memory_file(token_json(enrollment, keyslot).encode()) as token_file:
        try:
            _cryptsetup(
                ["token", "import", f"--json-file={token_file}", device_path],
                secret_bearing=True,
            )
        except SignInError as import_error:
            try:
                _cryptsetup(
                    ["luksKillSlot", f"--key-file={new_key}", device_path, str(keyslot)],
                    secret_bearing=True,
                )
            except SignInError as release_error:
                raise SignInError(
                    f"{import_error} Releasing keyslot {keyslot} of {device_path} also failed: "
                    f"{release_error}"
                ) from import_error
            raise


def add_fido2_keyslot(device_path, existing_passphrase, enrollment):
    slots_before = _keyslot_numbers(device_path)
    with _in_memory_file(existing_passphrase.encode()) as existing_key, \
            _in_memory_file(passphrase(enrollment).encode()) as new_key:
        _cryptsetup(
            ["luksAddKey", *FAST_PBKDF, f"--key-file={existing_key}", device_path, new_key],
            secret_bearing=True,
        )
        added = _keyslot_numbers(device_path) - slots_before
        if len(added) != 1:
            raise SignInError(f"Expected one new keyslot on {device_path}, found {sorted(added)}.")
        (keyslot,) = added
        _import_token_or_release_keyslot(device_path, keyslot, new_key, enrollment)
