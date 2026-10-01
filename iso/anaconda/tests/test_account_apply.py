import unittest

import _paths

from pyanaconda.modules.common.structures.user import UserData

from vekrona_account.account_settings import (
    apply_account,
    is_account_complete,
    validate_hostname,
    validate_timezone,
    validate_username,
)
from vekrona_account.wheel_user import read_wheel_user, write_wheel_password


class FakeUsers:
    def __init__(self, users=(), root_locked=True):
        self.Users = UserData.to_structure_list(list(users))
        self.IsRootAccountLocked = root_locked


class FakeNetwork:
    def __init__(self, hostname="vekrona"):
        self.Hostname = hostname


class FakeTimezone:
    def __init__(self, timezone="UTC"):
        self.Timezone = timezone


def wheel(name="alice"):
    user = UserData()
    user.name = name
    user.groups = ["wheel"]
    return user


class CompletedTest(unittest.TestCase):
    def complete(self, users=None, network=None, timezone=None):
        return is_account_complete(
            users or FakeUsers([wheel()]), network or FakeNetwork(), timezone or FakeTimezone()
        )

    def test_complete_account(self):
        self.assertTrue(self.complete())

    def test_plain_utc_is_a_valid_timezone(self):
        self.assertTrue(self.complete(timezone=FakeTimezone("UTC")))

    def test_region_city_timezone_is_valid(self):
        self.assertTrue(self.complete(timezone=FakeTimezone("Europe/Berlin")))

    def test_unknown_timezone_is_incomplete(self):
        self.assertFalse(self.complete(timezone=FakeTimezone("Mars/Olympus")))

    def test_empty_timezone_is_incomplete(self):
        self.assertFalse(self.complete(timezone=FakeTimezone("")))

    def test_missing_wheel_user_is_incomplete(self):
        self.assertFalse(self.complete(users=FakeUsers()))

    def test_unlocked_root_is_incomplete(self):
        self.assertFalse(self.complete(users=FakeUsers([wheel()], root_locked=False)))

    def test_missing_hostname_is_incomplete(self):
        self.assertFalse(self.complete(network=FakeNetwork("")))

    def test_password_is_not_required(self):
        self.assertEqual(read_wheel_user(FakeUsers([wheel()])).password, "")
        self.assertTrue(self.complete())


class ApplyTest(unittest.TestCase):
    def apply(self, users, network=None, timezone=None, name="bob"):
        network = network or FakeNetwork("")
        timezone = timezone or FakeTimezone("")
        apply_account(users, network, timezone, name, "Bob B", "bobs-box", "Europe/Berlin")
        return network, timezone

    def test_writes_user_hostname_timezone_and_locks_root(self):
        users = FakeUsers(root_locked=False)
        network, timezone = self.apply(users)
        user = read_wheel_user(users)
        self.assertEqual((user.name, user.gecos), ("bob", "Bob B"))
        self.assertTrue(users.IsRootAccountLocked)
        self.assertEqual(network.Hostname, "bobs-box")
        self.assertEqual(timezone.Timezone, "Europe/Berlin")

    def test_renaming_keeps_the_password_already_set(self):
        users = FakeUsers([wheel("alice")])
        write_wheel_password(users, "correct horse")
        self.apply(users)
        user = read_wheel_user(users)
        self.assertEqual(user.name, "bob")
        self.assertTrue(user.password)
        self.assertTrue(user.is_crypted)

    def test_applied_account_is_complete(self):
        users = FakeUsers(root_locked=False)
        network, timezone = self.apply(users)
        self.assertTrue(is_account_complete(users, network, timezone))


class ValidationTest(unittest.TestCase):
    def test_timezone(self):
        self.assertIsNone(validate_timezone("UTC"))
        self.assertIsNone(validate_timezone("Etc/UTC"))
        self.assertIsNone(validate_timezone("America/New_York"))
        self.assertIsNotNone(validate_timezone(""))
        self.assertIsNotNone(validate_timezone("Nowhere/Land"))

    def test_username(self):
        self.assertIsNone(validate_username("alice"))
        self.assertIsNotNone(validate_username(""))
        self.assertIsNotNone(validate_username("Alice"))
        self.assertIsNotNone(validate_username("a" * 33))
        self.assertIsNotNone(validate_username("root"))

    def test_hostname(self):
        self.assertIsNone(validate_hostname("vekrona"))
        self.assertIsNotNone(validate_hostname(""))
        self.assertIsNotNone(validate_hostname("bad host"))


if __name__ == "__main__":
    unittest.main()
