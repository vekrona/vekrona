import re

from pyanaconda.core.i18n import _
from pyanaconda.core.users import check_username
from pyanaconda.network import is_valid_hostname
from pyanaconda.timezone import is_valid_timezone

from vekrona_account.wheel_user import read_wheel_user, write_wheel_identity

__all__ = [
    "account_status",
    "apply_account",
    "is_account_complete",
    "validate_hostname",
    "validate_timezone",
    "validate_username",
]

USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]*$")
USERNAME_MAX_LEN = 32


def validate_username(name):
    if not name:
        return _("A username is required.")
    if len(name) > USERNAME_MAX_LEN:
        return _("Username must be {} characters or fewer.").format(USERNAME_MAX_LEN)
    if not USERNAME_RE.match(name):
        return _("Use lowercase letters, digits, - and _, starting with a letter or _.")
    valid, message = check_username(name)
    return None if valid else message


def validate_hostname(hostname):
    if not hostname:
        return _("A hostname is required.")
    valid, message = is_valid_hostname(hostname, local=True)
    return None if valid else message


def validate_timezone(timezone):
    if not timezone:
        return _("A timezone is required.")
    if not is_valid_timezone(timezone):
        return _("Not a recognized timezone; pick one from the list.")
    return None


def is_account_complete(users_proxy, network_proxy, timezone_proxy):
    return (
        read_wheel_user(users_proxy) is not None
        and bool(users_proxy.IsRootAccountLocked)
        and bool(network_proxy.Hostname)
        and is_valid_timezone(timezone_proxy.Timezone)
    )


def account_status(user_name, complete, timezone):
    if user_name is None:
        return _("Not set up")
    if not complete:
        return _("Not finished")
    return _("{name} (admin), {timezone}").format(name=user_name, timezone=timezone)


def apply_account(users_proxy, network_proxy, timezone_proxy, name, gecos, hostname, timezone):
    write_wheel_identity(users_proxy, name, gecos)
    users_proxy.IsRootAccountLocked = True
    network_proxy.Hostname = hostname
    timezone_proxy.Timezone = timezone
