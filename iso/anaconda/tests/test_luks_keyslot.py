import base64
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import _paths

from vekrona_signin.core.errors import SignInError
from vekrona_signin.core.fido2_luks import FidoLuksEnrollment, passphrase, token_json
from vekrona_signin.core.luks import add_fido2_keyslot

DEVICE = "/dev/vda3"
EXISTING_PASSPHRASE = "existing-install-passphrase"
LUKS_UUID = "0a1b2c3d-0000-4000-8000-000000000001"
ENROLLMENT = FidoLuksEnrollment(
    credential_id=bytes(range(40)),
    salt=bytes(range(32)),
    secret=bytes(range(100, 132)),
)


class FakeCryptsetupTest(unittest.TestCase):
    def setUp(self):
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        binary = directory / "cryptsetup"
        binary.symlink_to(Path(__file__).resolve().parent / "fake_cryptsetup.py")
        self.state_path = directory / "state.json"
        self.write_state(fail_token_import=False)
        environment = {
            "PATH": f"{directory}{os.pathsep}{os.environ['PATH']}",
            "FAKE_CRYPTSETUP_STATE": str(self.state_path),
        }
        patcher = mock.patch.dict(os.environ, environment)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write_state(self, fail_token_import):
        self.state_path.write_text(json.dumps({
            "keyslots": {"0": EXISTING_PASSPHRASE},
            "existing_passphrase": EXISTING_PASSPHRASE,
            "uuids": {DEVICE: LUKS_UUID},
            "fail_token_import": fail_token_import,
            "calls": [],
        }))

    def state(self):
        return json.loads(self.state_path.read_text())

    def calls(self, command):
        return [call for call in self.state()["calls"] if call["argv"][0] == command]


class AddingFido2KeyslotTest(FakeCryptsetupTest):
    def setUp(self):
        super().setUp()
        add_fido2_keyslot(DEVICE, EXISTING_PASSPHRASE, ENROLLMENT)

    def test_secrets_never_appear_in_command_lines(self):
        everything = json.dumps([call["argv"] for call in self.state()["calls"]])
        self.assertNotIn(EXISTING_PASSPHRASE, everything)
        self.assertNotIn(passphrase(ENROLLMENT), everything)
        self.assertNotIn(ENROLLMENT.secret.hex(), everything)

    def test_new_keyslot_is_unlocked_by_the_security_key_secret(self):
        self.assertEqual(self.state()["keyslots"]["1"], passphrase(ENROLLMENT))

    def test_existing_passphrase_authorizes_the_new_keyslot(self):
        (add,) = self.calls("luksAddKey")
        self.assertEqual(add["key_file_content"], EXISTING_PASSPHRASE)

    def test_token_is_imported_once_and_points_at_exactly_the_new_keyslot(self):
        (token_import,) = self.calls("token")
        token = json.loads(token_import["json_file_content"])
        self.assertEqual(token, json.loads(token_json(ENROLLMENT, 1)))
        self.assertEqual(token["keyslots"], ["1"])

    def test_the_existing_keyslot_is_untouched(self):
        self.assertEqual(self.state()["keyslots"]["0"], EXISTING_PASSPHRASE)
        self.assertEqual(self.calls("luksKillSlot"), [])

    def test_secret_bytes_are_not_written_to_the_token(self):
        (token_import,) = self.calls("token")
        self.assertNotIn(base64.b64encode(ENROLLMENT.secret).decode(), token_import["json_file_content"])


class FailedTokenImportTest(FakeCryptsetupTest):
    def setUp(self):
        super().setUp()
        self.write_state(fail_token_import=True)
        with self.assertRaises(SignInError) as raised:
            add_fido2_keyslot(DEVICE, EXISTING_PASSPHRASE, ENROLLMENT)
        self.error = raised.exception

    def test_the_failure_is_surfaced(self):
        self.assertIn("token import refused", str(self.error))

    def test_only_the_just_added_keyslot_is_killed(self):
        (kill,) = self.calls("luksKillSlot")
        self.assertEqual(kill["argv"][-2:], [DEVICE, "1"])
        self.assertEqual(kill["key_file_content"], passphrase(ENROLLMENT))

    def test_keyslots_are_back_to_what_they_were_before(self):
        self.assertEqual(self.state()["keyslots"], {"0": EXISTING_PASSPHRASE})


class WrongPassphraseTest(FakeCryptsetupTest):
    def test_rejected_passphrase_is_surfaced_and_nothing_changes(self):
        with self.assertRaisesRegex(SignInError, "luksAddKey failed"):
            add_fido2_keyslot(DEVICE, "wrong", ENROLLMENT)
        self.assertEqual(self.state()["keyslots"], {"0": EXISTING_PASSPHRASE})
        self.assertEqual(self.calls("token"), [])


if __name__ == "__main__":
    unittest.main()
