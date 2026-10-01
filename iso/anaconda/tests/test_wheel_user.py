import unittest

import _paths

from pyanaconda.modules.common.structures.user import UserData

from vekrona_account.wheel_user import (
    WheelUserMissing,
    read_wheel_user,
    wheel_password_matches,
    write_wheel_identity,
    write_wheel_password,
)


class FakeUsersProxy:
    def __init__(self, users=()):
        self.Users = UserData.to_structure_list(list(users))


def make_user(name, groups, password="", is_crypted=True, gecos=""):
    user = UserData()
    user.name = name
    user.groups = list(groups)
    user.password = password
    user.is_crypted = is_crypted
    user.gecos = gecos
    return user


def stored_users(proxy):
    return UserData.from_structure_list(proxy.Users)


class ReadWheelUserTest(unittest.TestCase):
    def test_no_users_gives_none(self):
        self.assertIsNone(read_wheel_user(FakeUsersProxy()))

    def test_finds_the_admin_among_other_users(self):
        proxy = FakeUsersProxy([make_user("guest", []), make_user("alice", ["wheel"])])
        self.assertEqual(read_wheel_user(proxy).name, "alice")

    def test_only_non_admin_users_gives_none(self):
        self.assertIsNone(read_wheel_user(FakeUsersProxy([make_user("guest", ["users"])])))


class WriteIdentityTest(unittest.TestCase):
    def test_creates_the_admin_when_missing(self):
        proxy = FakeUsersProxy()
        write_wheel_identity(proxy, "alice", "Alice A")
        user = read_wheel_user(proxy)
        self.assertEqual((user.name, user.gecos), ("alice", "Alice A"))
        self.assertIn("wheel", user.groups)

    def test_rename_preserves_the_password_hash(self):
        proxy = FakeUsersProxy([make_user("old", ["wheel"], password="$6$salt$hash")])
        write_wheel_identity(proxy, "new", "New Name")
        user = read_wheel_user(proxy)
        self.assertEqual((user.name, user.password, user.is_crypted), ("new", "$6$salt$hash", True))

    def test_rename_preserves_a_plaintext_password(self):
        proxy = FakeUsersProxy([make_user("old", ["wheel"], password="secret", is_crypted=False)])
        write_wheel_identity(proxy, "new", "")
        user = read_wheel_user(proxy)
        self.assertEqual((user.password, user.is_crypted), ("secret", False))

    def test_other_users_are_kept(self):
        proxy = FakeUsersProxy([make_user("guest", []), make_user("old", ["wheel"])])
        write_wheel_identity(proxy, "new", "")
        self.assertEqual(sorted(user.name for user in stored_users(proxy)), ["guest", "new"])


class PasswordTest(unittest.TestCase):
    def test_password_is_stored_crypted_and_verifies(self):
        proxy = FakeUsersProxy([make_user("alice", ["wheel"])])
        write_wheel_password(proxy, "correct horse")
        user = read_wheel_user(proxy)
        self.assertTrue(user.is_crypted)
        self.assertNotIn("correct horse", user.password)
        self.assertTrue(wheel_password_matches(proxy, "correct horse"))
        self.assertFalse(wheel_password_matches(proxy, "wrong horse"))

    def test_password_survives_a_rename(self):
        proxy = FakeUsersProxy([make_user("alice", ["wheel"])])
        write_wheel_password(proxy, "correct horse")
        write_wheel_identity(proxy, "bob", "")
        self.assertTrue(wheel_password_matches(proxy, "correct horse"))

    def test_setting_a_password_without_an_account_is_an_error(self):
        with self.assertRaises(WheelUserMissing):
            write_wheel_password(FakeUsersProxy(), "correct horse")

    def test_no_account_never_matches(self):
        self.assertFalse(wheel_password_matches(FakeUsersProxy(), "x"))

    def test_account_without_password_never_matches(self):
        proxy = FakeUsersProxy([make_user("alice", ["wheel"])])
        self.assertFalse(wheel_password_matches(proxy, ""))

    def test_locked_hash_never_matches(self):
        proxy = FakeUsersProxy([make_user("alice", ["wheel"], password="!")])
        self.assertFalse(wheel_password_matches(proxy, "!"))

    def test_plaintext_kickstart_password_matches(self):
        proxy = FakeUsersProxy([make_user("alice", ["wheel"], password="vekrona", is_crypted=False)])
        self.assertTrue(wheel_password_matches(proxy, "vekrona"))
        self.assertFalse(wheel_password_matches(proxy, "other"))


if __name__ == "__main__":
    unittest.main()
