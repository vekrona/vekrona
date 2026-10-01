import unittest

import _paths

from vekrona_signin.gui.signin_state import EncryptionGuard
from vekrona_signin.core.secret import Secret


class SecretTest(unittest.TestCase):
    def test_text_never_shows_in_str_or_repr(self):
        secret = Secret("hunter2 hunter2")
        self.assertNotIn("hunter2", f"{secret} {secret!r}")
        self.assertEqual(secret.reveal(), "hunter2 hunter2")

    def test_the_guard_keeps_the_password_in_a_secret(self):
        guard = EncryptionGuard()
        guard.accept_password("hunter2 hunter2")
        self.assertEqual(guard.password, "hunter2 hunter2")
        self.assertNotIn("hunter2", repr(vars(guard)))


if __name__ == "__main__":
    unittest.main()
