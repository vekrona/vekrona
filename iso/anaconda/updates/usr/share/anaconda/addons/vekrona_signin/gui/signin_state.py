from dataclasses import dataclass
from enum import Enum

from pyanaconda.core.i18n import _

from vekrona_signin.core.password_policy import PasswordState
from vekrona_signin.core.storage_policy import StorageState
from vekrona_signin.gui.spokes import guidance

__all__ = [
    "EncryptionGuard",
    "HubSignal",
    "HubView",
    "Snapshot",
    "StorageReaction",
    "hub_signal",
    "hub_status",
    "leave_blocker",
    "password_feedback",
    "screen_notice",
]


@dataclass(frozen=True)
class Snapshot:
    username: str = ""
    has_password: bool = False
    storage_state: StorageState = StorageState.NOT_APPLIED
    applied_path: str = ""
    key_registered: bool = False
    finger_enrolled: bool = False
    error: str = ""

    @property
    def has_account(self):
        return bool(self.username)

    @property
    def completed(self):
        return not self.error and self.has_password and self.storage_state is StorageState.MATCH


class StorageReaction(Enum):
    IGNORE = "ignore"
    ENCRYPTED = "encrypted"
    RECONCILE = "reconcile"
    REEVALUATE = "reevaluate"


class EncryptionGuard:
    def __init__(self):
        self.password = None
        self.account_error = ""
        self.applying = False
        self.failure = ""
        self._generation = 0
        self._failed_on = None

    def accept_password(self, password):
        self.password = password
        self._generation += 1
        self.failure = ""
        self._failed_on = None

    def should_encrypt(self, storage_state):
        return (
            self.password is not None
            and not self.applying
            and storage_state not in (StorageState.MATCH, StorageState.NO_DISK)
        )

    def react_to_storage_change(self, snapshot):
        if self.applying:
            return StorageReaction.IGNORE
        if (
            snapshot.storage_state is StorageState.MISMATCH
            and self.password is not None
            and self._failed_on != (snapshot.applied_path, self._generation)
        ):
            return StorageReaction.RECONCILE
        return StorageReaction.REEVALUATE

    def begin(self):
        self.applying = True

    def finish(self, snapshot, error, applied_by_us):
        self.applying = False
        if not error and snapshot.applied_path != applied_by_us:
            return self.react_to_storage_change(snapshot)
        if not error and snapshot.storage_state is not StorageState.MATCH:
            error = _(guidance.STATUS_STORAGE_STILL_PLAIN)
        if error:
            self.failure = error
            self._failed_on = (snapshot.applied_path, self._generation)
            return StorageReaction.REEVALUATE
        self.failure = ""
        self._failed_on = None
        return StorageReaction.ENCRYPTED


def _methods_status(snapshot):
    methods = [
        _(name)
        for registered, name in (
            (snapshot.key_registered, guidance.STATUS_METHOD_KEY),
            (snapshot.finger_enrolled, guidance.STATUS_METHOD_FINGERPRINT),
        )
        if registered
    ]
    if not methods:
        return _(guidance.STATUS_PASSWORD_ONLY)
    return _(guidance.STATUS_WITH_METHODS).format(methods=" + ".join(methods))


class Problem(Enum):
    PASSWORD_NOT_SAVED = "password_not_saved"
    STATE_UNREADABLE = "state_unreadable"
    ENCRYPTION_FAILED = "encryption_failed"


def _problem(snapshot, guard):
    if guard.account_error:
        return Problem.PASSWORD_NOT_SAVED
    if snapshot.error:
        return Problem.STATE_UNREADABLE
    if (
        snapshot.has_account
        and snapshot.has_password
        and not guard.applying
        and snapshot.storage_state is not StorageState.MATCH
        and guard.failure
    ):
        return Problem.ENCRYPTION_FAILED
    return None


def _problem_detail(problem, snapshot, guard):
    return {
        Problem.PASSWORD_NOT_SAVED: guard.account_error,
        Problem.STATE_UNREADABLE: snapshot.error,
        Problem.ENCRYPTION_FAILED: guard.failure,
    }[problem]


_PROBLEM_STATUS = {
    Problem.PASSWORD_NOT_SAVED: guidance.STATUS_PASSWORD_NOT_SAVED,
    Problem.STATE_UNREADABLE: guidance.STATUS_STATE_UNREADABLE,
    Problem.ENCRYPTION_FAILED: guidance.STATUS_ENCRYPTION_FAILED,
}

_PROBLEM_NOTICE = {
    Problem.PASSWORD_NOT_SAVED: guidance.NOTICE_PASSWORD_NOT_SAVED,
    Problem.STATE_UNREADABLE: guidance.NOTICE_STATE_UNREADABLE,
    Problem.ENCRYPTION_FAILED: guidance.NOTICE_ENCRYPTION_FAILED,
}


def hub_status(snapshot, guard):
    problem = _problem(snapshot, guard)
    if problem is not None:
        return _(_PROBLEM_STATUS[problem])
    if not snapshot.has_account:
        return _(guidance.DISABLED_NO_ACCOUNT)
    if guard.applying:
        return _(guidance.STATUS_APPLYING)
    if not snapshot.has_password:
        return _(guidance.STATUS_SET_PASSWORD)
    if snapshot.storage_state is StorageState.MATCH:
        return _methods_status(snapshot)
    if snapshot.storage_state is StorageState.NO_DISK:
        return _(guidance.STATUS_CHOOSE_DISK)
    if snapshot.storage_state is StorageState.NOT_APPLIED:
        return _(guidance.STATUS_DISK_NOT_SET_UP)
    return _(guidance.STATUS_STORAGE_CHANGED)


def screen_notice(snapshot, guard):
    problem = _problem(snapshot, guard)
    if problem is None:
        return ""
    return _(_PROBLEM_NOTICE[problem]).format(error=_problem_detail(problem, snapshot, guard))


def password_feedback(state, confirm, min_length):
    if state is PasswordState.VALID:
        return ""
    if state in (PasswordState.EMPTY, PasswordState.MISMATCH) and not confirm:
        return ""
    return guidance.password_state_error(state, min_length)


def leave_blocker(state, password, confirm, min_length):
    if state is PasswordState.VALID or (not password and not confirm):
        return ""
    return guidance.password_state_error(state, min_length)


@dataclass(frozen=True)
class HubView:
    ready: bool
    completed: bool
    status: str


class HubSignal(Enum):
    NONE = "none"
    READY = "ready"
    NOT_READY = "not_ready"
    MESSAGE = "message"


def hub_signal(shown, current):
    if not current.ready:
        return HubSignal.NONE if shown is not None and not shown.ready else HubSignal.NOT_READY
    if shown is None or not shown.ready or shown.completed != current.completed:
        return HubSignal.READY
    if shown.status != current.status:
        return HubSignal.MESSAGE
    return HubSignal.NONE
