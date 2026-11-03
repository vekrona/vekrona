import base64
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _paths

from vekrona_signin.core.device_description import DeviceDescription
from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.fido2_luks import FidoLuksEnrollment, passphrase, token_json
from vekrona_signin.core.fprint import find_reader, storage_path
from vekrona_signin.core.luks import parse_keyslot_numbers
from vekrona_signin.core.pam_u2f import format_u2f_line
from vekrona_signin.core.private_files import write_private_file
from vekrona_signin.core.security_key import find_descriptor
from vekrona_signin.core import u2f_mappings
from vekrona_signin.core.u2f_mappings import merge_u2f_mappings, write_u2f_mappings

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

    def test_line_requires_presence_only_because_pin_policy_lives_in_pam(self):
        self.assertTrue(self.line.endswith(",es256,+presence"))
        self.assertNotIn("+pin", self.line)


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


ALICE_LINE = "alice:aB1=,cD2=,es256,+presence"
BOB_LINE = "bob:eF3=,gH4=,es256,+presence"


class MergeU2fMappingsTest(unittest.TestCase):
    def test_first_registration_is_the_line_and_a_newline(self):
        self.assertEqual(merge_u2f_mappings("", "alice", ALICE_LINE), ALICE_LINE + "\n")

    def test_other_users_lines_stay_and_the_new_line_comes_last(self):
        self.assertEqual(merge_u2f_mappings(BOB_LINE + "\n", "alice", ALICE_LINE), f"{BOB_LINE}\n{ALICE_LINE}\n")

    def test_an_older_line_of_the_user_is_replaced(self):
        existing = f"alice:old=,old=,es256,+presence\n{BOB_LINE}\n"
        self.assertEqual(merge_u2f_mappings(existing, "alice", ALICE_LINE), f"{BOB_LINE}\n{ALICE_LINE}\n")

    def test_a_missing_final_newline_and_blank_lines_do_not_leak_into_the_result(self):
        self.assertEqual(merge_u2f_mappings(f"\n{BOB_LINE}", "alice", ALICE_LINE), f"{BOB_LINE}\n{ALICE_LINE}\n")

    def test_a_user_whose_name_starts_like_another_keeps_the_others_line(self):
        self.assertEqual(
            merge_u2f_mappings(ALICE_LINE + "\n", "al", "al:x=,y=,es256,+presence"),
            f"{ALICE_LINE}\nal:x=,y=,es256,+presence\n",
        )

    def test_a_line_for_another_user_is_refused(self):
        for user, line in (("alice", BOB_LINE), ("alice", "root:x=,y=,es256,+presence"), ("al", ALICE_LINE), ("alice", "")):
            with self.subTest(user=user, line=line), self.assertRaises(SignInError):
                merge_u2f_mappings("", user, line)

    def test_a_line_that_smuggles_a_second_entry_is_refused(self):
        for line in (ALICE_LINE + "\nroot:x=,y=,es256,+presence", ALICE_LINE + "\rroot:x=,y=,es256,+presence"):
            with self.subTest(line=line), self.assertRaises(SignInError):
                merge_u2f_mappings("", "alice", line)


class WriteU2fMappingsTest(unittest.TestCase):
    def setUp(self):
        self.sysroot = tempfile.TemporaryDirectory()
        self.addCleanup(self.sysroot.cleanup)
        self.etc = Path(self.sysroot.name) / "etc"
        self.etc.mkdir()
        self.path = self.etc / "u2f_mappings"

    def write(self, username, line):
        write_u2f_mappings(self.sysroot.name, username, line, os.getuid(), os.getgid())

    def test_file_is_world_readable_and_owned_as_asked(self):
        self.write("alice", ALICE_LINE)
        self.assertEqual(self.path.read_text(), ALICE_LINE + "\n")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644)
        self.assertEqual((self.path.stat().st_uid, self.path.stat().st_gid), (os.getuid(), os.getgid()))

    def test_existing_file_is_merged_not_replaced(self):
        self.path.write_text(BOB_LINE + "\n")
        self.write("alice", ALICE_LINE)
        self.assertEqual(self.path.read_text(), f"{BOB_LINE}\n{ALICE_LINE}\n")

    def test_no_temporary_file_is_left_beside_it(self):
        self.write("alice", ALICE_LINE)
        self.assertEqual([p.name for p in self.etc.iterdir()], ["u2f_mappings"])

    def test_a_failed_rename_leaves_the_old_file_whole_and_no_temporary_file(self):
        self.path.write_text(BOB_LINE + "\n")
        with mock.patch.object(u2f_mappings.os, "replace", side_effect=OSError("rename failed")):
            with self.assertRaises(OSError):
                self.write("alice", ALICE_LINE)
        self.assertEqual(self.path.read_text(), BOB_LINE + "\n")
        self.assertEqual([p.name for p in self.etc.iterdir()], ["u2f_mappings"])

    def test_a_refused_line_leaves_the_file_alone(self):
        self.path.write_text(BOB_LINE + "\n")
        with self.assertRaises(SignInError):
            self.write("alice", BOB_LINE)
        self.assertEqual(self.path.read_text(), BOB_LINE + "\n")
        self.assertEqual([p.name for p in self.etc.iterdir()], ["u2f_mappings"])


class PrivateFileTest(unittest.TestCase):
    def test_file_is_private_and_created_directories_are_too(self):
        with tempfile.TemporaryDirectory() as base:
            path = Path(base) / "var/lib/fprint/alice"
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
