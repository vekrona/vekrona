import unittest

import _paths

from vekrona_signin.core.password_policy import PasswordState
from vekrona_signin.core.storage_policy import StorageState
from vekrona_signin.gui.signin_state import (
    EncryptionGuard,
    HubSignal,
    HubView,
    Snapshot,
    StorageReaction,
    hub_signal,
    hub_status,
    leave_blocker,
    password_feedback,
    screen_notice,
)
from vekrona_signin.gui.spokes import guidance

PASSWORD = "correct horse"
STOCK_PATH = "/Partitioning/3"
OUR_PATH = "/Partitioning/4"
NEWER_STOCK_PATH = "/Partitioning/5"


def snapshot(state, path=STOCK_PATH, **fields):
    defaults = {"username": "alice", "has_password": True}
    defaults.update(fields)
    return Snapshot(storage_state=state, applied_path=path, **defaults)


def guard_with_password():
    guard = EncryptionGuard()
    guard.accept_password(PASSWORD)
    return guard


class CompletenessTest(unittest.TestCase):
    def test_account_password_and_matching_encrypted_layout_complete_the_screen(self):
        self.assertTrue(snapshot(StorageState.MATCH).completed)

    def test_kickstart_layout_not_yet_applied_is_incomplete(self):
        self.assertFalse(snapshot(StorageState.NOT_APPLIED).completed)

    def test_layout_with_another_passphrase_is_incomplete(self):
        self.assertFalse(snapshot(StorageState.MISMATCH).completed)

    def test_account_without_password_is_incomplete(self):
        self.assertFalse(snapshot(StorageState.MATCH, has_password=False).completed)

    def test_unreadable_state_is_incomplete(self):
        self.assertFalse(Snapshot(error="boom").completed)


class EncryptAfterPasswordTest(unittest.TestCase):
    def test_without_a_password_nothing_is_encrypted(self):
        guard = EncryptionGuard()
        for state in StorageState:
            with self.subTest(state):
                self.assertFalse(guard.should_encrypt(state))

    def test_every_layout_but_a_matching_one_is_encrypted_once_a_password_is_set(self):
        guard = guard_with_password()
        for state in (StorageState.NOT_APPLIED, StorageState.MISMATCH, StorageState.NOT_AUTOMATIC):
            with self.subTest(state):
                self.assertTrue(guard.should_encrypt(state))

    def test_matching_layout_is_left_alone(self):
        self.assertFalse(guard_with_password().should_encrypt(StorageState.MATCH))

    def test_without_a_disk_nothing_is_created(self):
        self.assertFalse(guard_with_password().should_encrypt(StorageState.NO_DISK))

    def test_no_second_encryption_while_one_runs(self):
        guard = guard_with_password()
        guard.begin()
        self.assertFalse(guard.should_encrypt(StorageState.NOT_APPLIED))


class StockSpokeReactionTest(unittest.TestCase):
    def test_own_apply_never_triggers_a_reconcile(self):
        guard = guard_with_password()
        guard.begin()
        for state in StorageState:
            with self.subTest(state):
                self.assertIs(guard.react_to_storage_change(snapshot(state, OUR_PATH)), StorageReaction.IGNORE)

    def test_stock_layout_without_encryption_is_reconciled(self):
        guard = guard_with_password()
        self.assertIs(guard.react_to_storage_change(snapshot(StorageState.MISMATCH)), StorageReaction.RECONCILE)

    def test_stock_layout_with_the_password_only_reevaluates(self):
        guard = guard_with_password()
        self.assertIs(guard.react_to_storage_change(snapshot(StorageState.MATCH)), StorageReaction.REEVALUATE)

    def test_without_a_typed_password_a_mismatch_cannot_be_reconciled(self):
        self.assertIs(
            EncryptionGuard().react_to_storage_change(snapshot(StorageState.MISMATCH)), StorageReaction.REEVALUATE
        )

    def test_reset_layout_is_not_reconciled_because_the_stock_spoke_is_still_working(self):
        guard = guard_with_password()
        self.assertIs(
            guard.react_to_storage_change(snapshot(StorageState.NOT_APPLIED, "")), StorageReaction.REEVALUATE
        )

    def test_failed_reconcile_is_not_retried_for_the_same_layout_and_password(self):
        guard = guard_with_password()
        guard.begin()
        self.assertIs(guard.finish(snapshot(StorageState.MISMATCH), "not enough space", ""), StorageReaction.REEVALUATE)
        self.assertIs(guard.react_to_storage_change(snapshot(StorageState.MISMATCH)), StorageReaction.REEVALUATE)

    def test_failed_reconcile_is_retried_when_the_stock_spoke_applies_a_new_layout(self):
        guard = guard_with_password()
        guard.begin()
        guard.finish(snapshot(StorageState.MISMATCH), "not enough space", "")
        self.assertIs(
            guard.react_to_storage_change(snapshot(StorageState.MISMATCH, NEWER_STOCK_PATH)),
            StorageReaction.RECONCILE,
        )

    def test_failed_reconcile_is_retried_after_a_new_password(self):
        guard = guard_with_password()
        guard.begin()
        guard.finish(snapshot(StorageState.MISMATCH), "not enough space", "")
        guard.accept_password("another password")
        self.assertIs(guard.react_to_storage_change(snapshot(StorageState.MISMATCH)), StorageReaction.RECONCILE)

    def test_apply_that_still_leaves_the_layout_plain_counts_as_failed(self):
        guard = guard_with_password()
        guard.begin()
        self.assertIs(guard.finish(snapshot(StorageState.MISMATCH, OUR_PATH), "", OUR_PATH), StorageReaction.REEVALUATE)
        self.assertEqual(guard.failure, guidance.STATUS_STORAGE_STILL_PLAIN)
        self.assertIs(
            guard.react_to_storage_change(snapshot(StorageState.MISMATCH, OUR_PATH)), StorageReaction.REEVALUATE
        )


class VisitOrderTest(unittest.TestCase):
    def test_account_then_sign_in_then_disk(self):
        guard = EncryptionGuard()
        guard.accept_password(PASSWORD)
        self.assertTrue(guard.should_encrypt(StorageState.NOT_APPLIED))
        guard.begin()
        self.assertIs(guard.finish(snapshot(StorageState.MATCH, OUR_PATH), "", OUR_PATH), StorageReaction.ENCRYPTED)
        stock_done = snapshot(StorageState.MATCH, NEWER_STOCK_PATH)
        self.assertIs(guard.react_to_storage_change(stock_done), StorageReaction.REEVALUATE)
        self.assertTrue(stock_done.completed)
        self.assertEqual(hub_status(stock_done, guard), guidance.STATUS_PASSWORD_ONLY)

    def test_disk_then_account_then_sign_in(self):
        guard = EncryptionGuard()
        plain = snapshot(StorageState.MISMATCH, has_password=False)
        self.assertIs(guard.react_to_storage_change(plain), StorageReaction.REEVALUATE)
        guard.accept_password(PASSWORD)
        self.assertTrue(guard.should_encrypt(StorageState.MISMATCH))
        guard.begin()
        self.assertIs(guard.react_to_storage_change(snapshot(StorageState.MATCH, OUR_PATH)), StorageReaction.IGNORE)
        encrypted = snapshot(StorageState.MATCH, OUR_PATH)
        self.assertIs(guard.finish(encrypted, "", OUR_PATH), StorageReaction.ENCRYPTED)
        self.assertEqual(hub_status(encrypted, guard), guidance.STATUS_PASSWORD_ONLY)

    def test_status_after_a_reapply_describes_the_matching_layout_only(self):
        guard = guard_with_password()
        guard.begin()
        guard.finish(snapshot(StorageState.MATCH, OUR_PATH), "", OUR_PATH)
        unticked = snapshot(StorageState.MISMATCH, NEWER_STOCK_PATH)
        self.assertIs(guard.react_to_storage_change(unticked), StorageReaction.RECONCILE)
        guard.begin()
        reapplied = snapshot(StorageState.MATCH, NEWER_STOCK_PATH, key_registered=True)
        guard.finish(reapplied, "", NEWER_STOCK_PATH)
        self.assertEqual(
            hub_status(reapplied, guard), guidance.STATUS_WITH_METHODS.format(methods="security key")
        )


class StockApplyDuringOursTest(unittest.TestCase):
    def test_stock_layout_landing_after_ours_is_reconciled_instead_of_failing(self):
        guard = guard_with_password()
        guard.begin()
        reaction = guard.finish(snapshot(StorageState.MISMATCH, NEWER_STOCK_PATH), "", OUR_PATH)
        self.assertIs(reaction, StorageReaction.RECONCILE)
        self.assertEqual(guard.failure, "")

    def test_matching_stock_layout_landing_after_ours_is_accepted(self):
        guard = guard_with_password()
        guard.begin()
        reaction = guard.finish(snapshot(StorageState.MATCH, NEWER_STOCK_PATH), "", OUR_PATH)
        self.assertIs(reaction, StorageReaction.REEVALUATE)


class HubSignalTest(unittest.TestCase):
    def view(self, ready=True, completed=False, status="Set a password"):
        return HubView(ready=ready, completed=completed, status=status)

    def test_status_change_of_an_incomplete_ready_spoke_is_only_a_message(self):
        self.assertIs(hub_signal(self.view(), self.view(status="other")), HubSignal.MESSAGE)

    def test_becoming_complete_is_announced_as_ready(self):
        self.assertIs(hub_signal(self.view(), self.view(completed=True)), HubSignal.READY)

    def test_becoming_incomplete_is_announced_as_ready(self):
        self.assertIs(hub_signal(self.view(completed=True), self.view()), HubSignal.READY)

    def test_starting_work_is_announced_once(self):
        busy = self.view(ready=False)
        self.assertIs(hub_signal(self.view(), busy), HubSignal.NOT_READY)
        self.assertIs(hub_signal(busy, busy), HubSignal.NONE)

    def test_finishing_work_is_announced_as_ready(self):
        self.assertIs(hub_signal(self.view(ready=False), self.view()), HubSignal.READY)

    def test_nothing_changed_sends_nothing(self):
        self.assertIs(hub_signal(self.view(), self.view()), HubSignal.NONE)


class LeaveBlockerTest(unittest.TestCase):
    def test_empty_entries_may_be_left(self):
        self.assertEqual(leave_blocker(PasswordState.EMPTY, "", "", 8), "")

    def test_valid_password_may_be_left(self):
        self.assertEqual(leave_blocker(PasswordState.VALID, "longenough", "longenough", 8), "")

    def test_half_typed_password_blocks_leaving_with_its_error(self):
        self.assertEqual(leave_blocker(PasswordState.MISMATCH, "longenough", "", 8), guidance.ERR_PASSWORD_MISMATCH)

    def test_short_password_blocks_leaving(self):
        self.assertIn("8", leave_blocker(PasswordState.TOO_SHORT, "short", "short", 8))


class HubStatusTest(unittest.TestCase):
    def test_no_account_points_to_the_account_screen(self):
        self.assertEqual(hub_status(Snapshot(), EncryptionGuard()), guidance.DISABLED_NO_ACCOUNT)

    def test_unreadable_state_shows_the_error(self):
        unreadable = Snapshot(error="org.freedesktop.DBus.Error.NoReply")
        self.assertEqual(hub_status(unreadable, EncryptionGuard()), guidance.STATUS_STATE_UNREADABLE)
        self.assertIn("NoReply", screen_notice(unreadable, EncryptionGuard()))

    def test_running_encryption_is_shown(self):
        guard = guard_with_password()
        guard.begin()
        self.assertEqual(hub_status(snapshot(StorageState.NOT_APPLIED), guard), guidance.STATUS_APPLYING)

    def test_account_without_password_asks_for_one(self):
        status = hub_status(snapshot(StorageState.MATCH, has_password=False), EncryptionGuard())
        self.assertEqual(status, guidance.STATUS_SET_PASSWORD)

    def test_registered_methods_are_listed(self):
        status = hub_status(
            snapshot(StorageState.MATCH, key_registered=True, finger_enrolled=True), EncryptionGuard()
        )
        self.assertEqual(status, guidance.STATUS_WITH_METHODS.format(methods="security key + fingerprint"))

    def test_failed_encryption_shows_its_error(self):
        guard = guard_with_password()
        guard.begin()
        guard.finish(snapshot(StorageState.MISMATCH), "Not enough space on the selected disks.", "")
        self.assertEqual(hub_status(snapshot(StorageState.MISMATCH), guard), guidance.STATUS_ENCRYPTION_FAILED)

    def test_failed_encryption_explains_itself_on_the_screen(self):
        guard = guard_with_password()
        guard.begin()
        guard.finish(snapshot(StorageState.MISMATCH), "Not enough space on the selected disks.", "")
        notice = screen_notice(snapshot(StorageState.MISMATCH), guard)
        self.assertEqual(notice, guidance.NOTICE_ENCRYPTION_FAILED.format(error="Not enough space on the selected disks."))

    def test_failure_notice_ends_once_the_layout_matches(self):
        guard = guard_with_password()
        guard.begin()
        guard.finish(snapshot(StorageState.MISMATCH), "Not enough space on the selected disks.", "")
        self.assertEqual(screen_notice(snapshot(StorageState.MATCH), guard), "")

    def test_healthy_screen_has_no_notice(self):
        self.assertEqual(screen_notice(snapshot(StorageState.MATCH), guard_with_password()), "")

    def test_failed_password_write_is_shown_until_a_write_succeeds(self):
        guard = guard_with_password()
        guard.account_error = "org.freedesktop.DBus.Error.NoReply"
        self.assertEqual(hub_status(snapshot(StorageState.MATCH), guard), guidance.STATUS_PASSWORD_NOT_SAVED)
        self.assertIn("NoReply", screen_notice(snapshot(StorageState.MATCH), guard))

    def test_missing_disk_tells_the_user_to_choose_one(self):
        status = hub_status(snapshot(StorageState.NO_DISK), guard_with_password())
        self.assertEqual(status, guidance.STATUS_CHOOSE_DISK)

    def test_layout_not_applied_points_to_installation_destination(self):
        status = hub_status(snapshot(StorageState.NOT_APPLIED), EncryptionGuard())
        self.assertEqual(status, guidance.STATUS_DISK_NOT_SET_UP)

    def test_mismatch_without_a_typed_password_asks_to_confirm_it(self):
        status = hub_status(snapshot(StorageState.MISMATCH), EncryptionGuard())
        self.assertEqual(status, guidance.STATUS_STORAGE_CHANGED)


class PasswordFeedbackTest(unittest.TestCase):
    def test_nothing_typed_shows_nothing(self):
        self.assertEqual(password_feedback(PasswordState.EMPTY, "", 8), "")

    def test_typing_the_first_field_does_not_complain_about_the_second(self):
        self.assertEqual(password_feedback(PasswordState.MISMATCH, "", 8), "")

    def test_short_password_names_the_minimum(self):
        self.assertIn("10", password_feedback(PasswordState.TOO_SHORT, "", 10))

    def test_different_confirmation_is_shown(self):
        self.assertEqual(password_feedback(PasswordState.MISMATCH, "x", 8), guidance.ERR_PASSWORD_MISMATCH)

    def test_confirmation_without_password_asks_for_the_password(self):
        self.assertEqual(password_feedback(PasswordState.EMPTY, "x", 8), guidance.ERR_PASSWORD_EMPTY)

    def test_valid_password_shows_nothing(self):
        self.assertEqual(password_feedback(PasswordState.VALID, "x", 8), "")


if __name__ == "__main__":
    unittest.main()
