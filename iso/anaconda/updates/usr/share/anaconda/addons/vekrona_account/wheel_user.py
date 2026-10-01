import hmac

from pyanaconda.core.i18n import _
from pyanaconda.core.users import crypt_password
from pyanaconda.modules.common.structures.user import UserData

try:
    import crypt_r
except ImportError:
    import crypt as crypt_r

__all__ = [
    "WheelUserMissing",
    "read_wheel_user",
    "wheel_password_matches",
    "write_wheel_identity",
    "write_wheel_password",
]


class WheelUserMissing(RuntimeError):
    pass


def _all_users(users_proxy):
    return UserData.from_structure_list(users_proxy.Users)


def _store(users_proxy, users):
    users_proxy.Users = UserData.to_structure_list(users)


def read_wheel_user(users_proxy):
    for user in _all_users(users_proxy):
        if user.has_admin_priviledges():
            return user
    return None


def _update_wheel_user(users_proxy, update):
    users = _all_users(users_proxy)
    for index, user in enumerate(users):
        if user.has_admin_priviledges():
            update(user)
            break
    else:
        user = UserData()
        user.set_admin_priviledges(True)
        update(user)
        users.append(user)
    _store(users_proxy, users)


def write_wheel_identity(users_proxy, name, gecos):
    def update(user):
        user.name = name
        user.gecos = gecos

    _update_wheel_user(users_proxy, update)


def write_wheel_password(users_proxy, plaintext):
    if read_wheel_user(users_proxy) is None:
        raise WheelUserMissing(_("Cannot set the password: the account is not set up yet."))

    def update(user):
        user.password = crypt_password(plaintext)
        user.is_crypted = True

    _update_wheel_user(users_proxy, update)


def wheel_password_matches(users_proxy, plaintext):
    user = read_wheel_user(users_proxy)
    if user is None or not user.password:
        return False
    if not user.is_crypted:
        return hmac.compare_digest(user.password.encode(), plaintext.encode())
    if not user.password.startswith("$"):
        return False
    return hmac.compare_digest(
        crypt_r.crypt(plaintext, user.password).encode(), user.password.encode()
    )
