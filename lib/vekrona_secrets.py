"""The secrets vekrona-vpn keeps for the user: the Mullvad account number and device, the Proton session and seed, and the keys of
imported configurations. They live in the Secret Service (the login collection of gnome-keyring) and nowhere else. secret-tool takes a value on stdin and gives it
back on stdout, so a key never reaches an argument of a process. Only user-side code calls this module; the root helper never does.

An item has the attributes application, kind and id, and its secret is one JSON object. An error names the item by its kind and
id, never by its value."""
import json
import subprocess
from typing import Dict, List, Optional, Tuple

import vekrona_vpn as vpn
from vekrona_vpn import VpnError

TOOL = "secret-tool"
APPLICATION = "vekrona-vpn"
# An unlock prompt waits for the person at the keyboard, so a call of secret-tool may take far longer than a command of the tool.
SECRET_PROMPT_WAIT_SEC = 600
MULLVAD_ACCOUNT = "mullvad-account"
MULLVAD_DEVICE = "mullvad-device"
CONFIG_KEY = "config-key"
PROTON_SESSION = "proton-session"
PROTON_KEY = "proton-key"
MULLVAD_ACCOUNT_ID = "account"
MULLVAD_DEVICE_ID = "device"
PROTON_SESSION_ID = "session"
PROTON_KEY_ID = "key"
# `secret-tool lookup` and `clear` exit with this status and print nothing when no item matches, and also when a prompt to unlock the
# collection is dismissed: the two cannot be told apart from secret-tool's answer, so the lock is asked for (locked).
NOT_FOUND = 1
BUSCTL = "busctl"
DEFAULT_COLLECTION = "/org/freedesktop/secrets/aliases/default"

Value = Dict[str, str]


def _attributes(kind: str, ident: str) -> list:
    return ["application", APPLICATION, "kind", kind, "id", ident]


def _unavailable(verb: str, kind: str, ident: str, exc: VpnError) -> VpnError:
    return VpnError("keyring locked or unavailable: cannot %s the %s of %s (%s)" % (verb, kind, ident, exc))


def _call(argv: list, verb: str, kind: str, ident: str, input_text: Optional[str] = None) -> None:
    try:
        vpn.run(argv, input_text=input_text, secret=True, timeout=SECRET_PROMPT_WAIT_SEC)
    except VpnError as exc:
        raise _unavailable(verb, kind, ident, exc)


def _locked() -> bool:
    """Whether the default collection of the Secret Service is locked, as the Secret Service says it (busctl)."""
    argv = [BUSCTL, "--user", "get-property", "org.freedesktop.secrets", DEFAULT_COLLECTION, "org.freedesktop.Secret.Collection", "Locked"]
    try:
        answer = vpn.run(argv).split()
    except VpnError as exc:
        raise VpnError("cannot ask the keyring whether it is locked: %s" % exc)
    if answer not in (["b", "true"], ["b", "false"]):
        raise VpnError("cannot read the lock of the keyring from busctl: %s" % " ".join(answer))
    return answer == ["b", "true"]


def _empty_miss(result: "subprocess.CompletedProcess[str]") -> bool:
    """secret-tool's answer for a missing item and for a dismissed unlock prompt: the status NOT_FOUND, nothing printed (a warning on
    stderr does not change it). Whether the keyring is locked decides between the two (_refuse_when_locked)."""
    return result.returncode == NOT_FOUND and result.stdout == ""


def _refuse_when_locked(verb: str, kind: str, ident: str) -> None:
    """Called for an empty miss: returns when the collection is unlocked (the item is missing, which is the answer), raises when locked."""
    if _locked():
        raise VpnError("keyring locked: cannot %s the %s of %s (the unlock was refused or dismissed)" % (verb, kind, ident))


def _item(kind: str, ident: str, text: str) -> Value:
    try:
        value = json.loads(text)
    except vpn.JSON_ERRORS:
        raise VpnError("the keyring item %s of %s is not JSON" % (kind, ident))
    if not isinstance(value, dict):
        raise VpnError("the keyring item %s of %s is not a JSON object" % (kind, ident))
    return value


def store(kind: str, ident: str, value: Value) -> None:
    """Keeps `value` as the item of `kind` and `ident`, replacing the one there is."""
    argv = [TOOL, "store", "--label=%s %s %s" % (APPLICATION, kind, ident), *_attributes(kind, ident)]
    _call(argv, "store", kind, ident, input_text=json.dumps(value))


def lookup_optional(kind: str, ident: str) -> Optional[Value]:
    """The item of `kind` and `ident`, or None when there is none (and the keyring is unlocked)."""
    argv = [TOOL, "lookup", *_attributes(kind, ident)]
    try:
        result = vpn.execute(argv, timeout=SECRET_PROMPT_WAIT_SEC)
    except VpnError as exc:
        raise _unavailable("read", kind, ident, exc)
    if _empty_miss(result):
        _refuse_when_locked("read", kind, ident)
        return None
    if result.returncode != 0:
        raise _unavailable("read", kind, ident, vpn.failure(argv, result, secret=True))
    return _item(kind, ident, result.stdout)


def lookup(kind: str, ident: str) -> Value:
    """The item of `kind` and `ident`; an error when there is none."""
    value = lookup_optional(kind, ident)
    if value is None:
        raise VpnError("the keyring holds no %s for %s" % (kind, ident))
    return value


Item = Tuple[str, str, Value]
Previous = Tuple[str, str, Optional[Value]]


def store_all(items: List[Item]) -> List[Previous]:
    """Stores every item, and returns what each one held before (None: nothing). What they held is read first, so a refused unlock
    fails before anything is stored; a store that fails puts back the items stored before it, and the error says whether that worked."""
    previous = [(kind, ident, lookup_optional(kind, ident)) for kind, ident, _ in items]
    done: List[Previous] = []
    try:
        for (kind, ident, value), old in zip(items, previous):
            store(kind, ident, value)
            done.append((kind, ident, old[2]))
    except VpnError as exc:
        problem = restore(done)
        raise exc if problem is None else VpnError("%s; and the keyring could not be put back: %s" % (exc, problem))
    return previous


def restore(previous: List[Previous]) -> Optional[str]:
    """Puts back what held before (last first): an item that held nothing is removed. A failing item does not stop the others; the
    returned text names every item that could not be put back, None when all were."""
    problems = []
    for kind, ident, old in reversed(previous):
        try:
            if old is None:
                clear(kind, ident)
            else:
                store(kind, ident, old)
        except VpnError as exc:
            problems.append("%s of %s: %s" % (kind, ident, exc))
    return "; ".join(problems) if problems else None


def clear(kind: str, ident: str) -> None:
    """Removes the item of `kind` and `ident`. An item that is not there is removed already, which is no error (while the keyring is
    unlocked)."""
    argv = [TOOL, "clear", *_attributes(kind, ident)]
    try:
        result = vpn.execute(argv, timeout=SECRET_PROMPT_WAIT_SEC)
    except VpnError as exc:
        raise _unavailable("clear", kind, ident, exc)
    if _empty_miss(result):
        _refuse_when_locked("clear", kind, ident)
        return
    if result.returncode != 0:
        raise _unavailable("clear", kind, ident, vpn.failure(argv, result, secret=True))
