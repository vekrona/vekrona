import base64
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

import _paths

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.fido2_luks import FidoLuksEnrollment, passphrase, token_json
from vekrona_signin.core.fprint import find_reader, storage_path
from vekrona_signin.core.luks import parse_keyslot_numbers
from vekrona_signin.core.pam_u2f import format_u2f_line
from vekrona_signin.core.passwd import parse_account
from vekrona_signin.core.private_files import write_private_file
from vekrona_signin.core.security_key import find_descriptor

ENROLLMENT = FidoLuksEnrollment(
    credential_id=bytes(range(40)),
    salt=bytes(range(32)),
    secret=bytes(range(100, 132)),
)


class PassphraseTest(unittest.TestCase):
    def test_passphrase_is_padded_standard_base64_of_the_secret(self):
        result = passphrase(ENROLLMENT)
        self.assertEqual(len(result), 44)
        self.assertTrue(result.endswith("="))
        self.assertEqual(base64.b64decode(result), ENROLLMENT.secret)

    def test_enrollment_repr_does_not_reveal_secrets(self):
        for rendering in (repr(ENROLLMENT), str(ENROLLMENT)):
            for secret in (ENROLLMENT.secret, ENROLLMENT.salt, ENROLLMENT.credential_id):
                self.assertNotIn(str(secret), rendering)
                self.assertNotIn(secret.hex(), rendering)
                self.assertNotIn(base64.b64encode(secret).decode(), rendering)


class SystemdTokenTest(unittest.TestCase):
    def setUp(self):
        self.token = json.loads(token_json(ENROLLMENT, 3))

    def test_token_has_exactly_the_systemd_fido2_keys(self):
        self.assertEqual(
            set(self.token),
            {
                "type", "keyslots", "fido2-credential", "fido2-salt", "fido2-rp",
                "fido2-clientPin-required", "fido2-up-required", "fido2-uv-required",
            },
        )

    def test_token_points_at_the_given_keyslot(self):
        self.assertEqual(self.token["type"], "systemd-fido2")
        self.assertEqual(self.token["keyslots"], ["3"])

    def test_token_carries_credential_and_salt_but_not_the_secret(self):
        self.assertEqual(base64.b64decode(self.token["fido2-credential"]), ENROLLMENT.credential_id)
        self.assertEqual(base64.b64decode(self.token["fido2-salt"]), ENROLLMENT.salt)
        self.assertNotIn(base64.b64encode(ENROLLMENT.secret).decode(), json.dumps(self.token))

    def test_token_marks_pin_and_presence_required(self):
        self.assertEqual(self.token["fido2-rp"], "io.systemd.cryptsetup")
        self.assertIs(self.token["fido2-clientPin-required"], True)
        self.assertIs(self.token["fido2-up-required"], True)
        self.assertIs(self.token["fido2-uv-required"], False)


class PamU2fLineTest(unittest.TestCase):
    def setUp(self):
        self.x = bytes([1]) * 32
        self.y = bytes([2]) * 32
        self.line = format_u2f_line("alice", b"credential-id", {-2: self.x, -3: self.y})

    def test_line_names_the_user_then_comma_separated_fields(self):
        user, fields = self.line.split(":")
        self.assertEqual(user, "alice")
        self.assertEqual(len(fields.split(",")), 4)

    def test_line_carries_credential_id_and_raw_public_key(self):
        _, fields = self.line.split(":")
        credential, public_key, algorithm, options = fields.split(",")
        self.assertEqual(base64.b64decode(credential), b"credential-id")
        self.assertEqual(base64.b64decode(public_key), self.x + self.y)
        self.assertEqual(algorithm, "es256")

    def test_line_requires_presence_and_pin(self):
        self.assertTrue(self.line.endswith(",es256,+presence+pin"))


class FprintStoragePathTest(unittest.TestCase):
    def test_path_follows_fprintd_layout(self):
        self.assertEqual(
            storage_path("/mnt/sysroot", "alice", "goodixmoc", "0123", 7),
            Path("/mnt/sysroot/var/lib/fprint/alice/goodixmoc/0123/7"),
        )

    def test_finger_is_named_in_hexadecimal(self):
        self.assertEqual(storage_path("/", "alice", "d", "i", 10).name, "a")


class KeyslotParsingTest(unittest.TestCase):
    DUMP = json.dumps({
        "keyslots": {"0": {"type": "luks2"}, "2": {"type": "luks2"}},
        "tokens": {},
        "segments": {"0": {}},
    })

    def test_keyslot_numbers_are_the_keys_of_the_keyslots_object(self):
        self.assertEqual(parse_keyslot_numbers(self.DUMP), {0, 2})

    def test_new_keyslot_is_the_difference_between_two_dumps(self):
        before = parse_keyslot_numbers(self.DUMP)
        after = parse_keyslot_numbers(json.dumps({"keyslots": {"0": {}, "1": {}, "2": {}}}))
        self.assertEqual(after - before, {1})


class PasswdTest(unittest.TestCase):
    PASSWD = "root:x:0:0:root:/root:/bin/bash\nalice:x:1000:1001:Alice:/home/alice:/bin/zsh\n"

    def test_account_carries_uid_gid_and_home(self):
        account = parse_account(self.PASSWD, "alice")
        self.assertEqual((account.uid, account.gid, account.home), (1000, 1001, "/home/alice"))

    def test_unknown_user_is_reported(self):
        with self.assertRaises(SignInError):
            parse_account(self.PASSWD, "bob")


class PrivateFileTest(unittest.TestCase):
    def test_file_is_private_and_created_directories_are_too(self):
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / ".config/Yubico/u2f_keys"
            write_private_file(Path(base), path, b"line\n", os.getuid(), os.getgid())
            self.assertEqual(path.read_bytes(), b"line\n")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            for directory in (path.parent, path.parent.parent):
                self.assertEqual(stat.S_IMODE(directory.stat().st_mode) & 0o077, 0)



class FakeDescriptor:
    def __init__(self, path):
        self.path = path


class FakeReader:
    def __init__(self, device_id):
        self.device_id = device_id

    def get_device_id(self):
        return self.device_id


class DeviceResolutionTest(unittest.TestCase):
    def test_security_key_is_found_by_its_path_not_by_position(self):
        descriptors = [FakeDescriptor("/dev/hidraw3"), FakeDescriptor("/dev/hidraw5")]
        self.assertIs(find_descriptor(descriptors[1:], "/dev/hidraw5"), descriptors[1])

    def test_unplugged_security_key_asks_for_refresh(self):
        with self.assertRaisesRegex(SignInError, "unplugged; press Check again"):
            find_descriptor([FakeDescriptor("/dev/hidraw3")], "/dev/hidraw5")

    def test_fingerprint_reader_is_found_by_its_device_id(self):
        readers = [FakeReader("a"), FakeReader("b")]
        self.assertIs(find_reader(readers[1:], "b"), readers[1])

    def test_unplugged_fingerprint_reader_asks_for_refresh(self):
        with self.assertRaisesRegex(SignInError, "unplugged; press Check again"):
            find_reader([FakeReader("a")], "b")


class DeviceDescriptionTest(unittest.TestCase):
    def test_description_survives_the_dbus_structure_round_trip(self):
        devices = [DeviceDescription.create("/dev/hidraw3", "Key (1050:0407)")]
        restored = DeviceDescription.from_structure_list(DeviceDescription.to_structure_list(devices))
        self.assertEqual([(d.id, d.name) for d in restored], [("/dev/hidraw3", "Key (1050:0407)")])

if __name__ == "__main__":
    unittest.main()
