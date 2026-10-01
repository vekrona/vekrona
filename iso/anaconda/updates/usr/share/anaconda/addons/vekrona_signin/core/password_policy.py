from enum import Enum

__all__ = ["MIN_PASSWORD_LENGTH", "PasswordState", "minimum_length", "validate"]

MIN_PASSWORD_LENGTH = 8


class PasswordState(Enum):
    EMPTY = "empty"
    TOO_SHORT = "too_short"
    MISMATCH = "mismatch"
    VALID = "valid"


def minimum_length(luks_policy_min_length):
    return max(MIN_PASSWORD_LENGTH, luks_policy_min_length)


def validate(password, confirm, min_length):
    if not password:
        return PasswordState.EMPTY
    if len(password) < min_length:
        return PasswordState.TOO_SHORT
    if password != confirm:
        return PasswordState.MISMATCH
    return PasswordState.VALID
