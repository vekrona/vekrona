from dataclasses import dataclass

from vekrona_signin.core.errors import SignInError

__all__ = ["Account", "parse_account"]


@dataclass(frozen=True)
class Account:
    uid: int
    gid: int
    home: str


def parse_account(passwd_text, username):
    for line in passwd_text.splitlines():
        fields = line.split(":")
        if len(fields) >= 6 and fields[0] == username:
            return Account(uid=int(fields[2]), gid=int(fields[3]), home=fields[5])
    raise SignInError(f"User {username} does not exist in the installed system.")
