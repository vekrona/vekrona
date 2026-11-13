"""Mullvad for vekrona-vpn: the account API (a new WireGuard device) and the relay list, with its cache. Runs as the user, before
the kill switch is armed or through the tunnel; the root helper never speaks to the network.

Ported from yolobox-network's egress.py."""
import getpass
import http.client
import ipaddress
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import vekrona_vpn
from vekrona_vpn import VpnError

MULLVAD_API = "https://api.mullvad.net"
USER_AGENT = "vekrona-vpn"
HTTP_TIMEOUT_SEC = 15
MAX_DEVICES_REACHED = "MAX_DEVICES_REACHED"
# The API is asked again for the relay list when its cache is older than this.
RELAYS_MAX_AGE_SEC = 24 * 60 * 60
WG_TOOL = vekrona_vpn.WG_TOOL


class ApiError(Exception):
    def __init__(self, message: str, status: Optional[int] = None, code: str = "") -> None:
        super().__init__(message)
        self.status = status
        self.code = code


def error_code(body: bytes) -> str:
    """The API's error code: `code`, or `type` for problem+json."""
    try:
        doc = json.loads(body)
    except vekrona_vpn.JSON_ERRORS:
        return ""
    if not isinstance(doc, dict):
        return ""
    for key in ("code", "type"):
        if isinstance(doc.get(key), str):
            return doc[key]
    return ""


def http_json(method: str, path: str, *, body: Optional[object] = None, token: Optional[str] = None,
              expect: Sequence[int] = (200,)) -> Any:
    """One JSON request to the API. Returns the parsed answer, or None for an empty one."""
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    request = urllib.request.Request(MULLVAD_API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SEC) as response:
            status, payload = response.status, response.read()
    except urllib.error.HTTPError as err:
        with err:
            code = error_code(err.read())
        raise ApiError("%s %s: HTTP %d%s" % (method, path, err.code, " " + code if code else ""), err.code, code)
    except (urllib.error.URLError, OSError, http.client.HTTPException) as err:
        raise ApiError("%s %s: %s" % (method, path, getattr(err, "reason", err)))
    if status not in expect:
        raise ApiError("%s %s: unexpected HTTP %d" % (method, path, status), status)
    if not payload:
        return None
    try:
        return json.loads(payload)
    except vekrona_vpn.JSON_ERRORS:
        raise ApiError("%s %s: the answer is not JSON" % (method, path))


# ---- The relay list -----------------------------------------------------------------------------------------------------

NO_RELAYS: Dict[str, Any] = {"names": {}, "relays": []}


def validate_relay_list(doc: object) -> dict:
    """The relay list as this tool keeps it: {"names": {cc: name}, "relays": [{hostname, country, public_key, ipv4}]}. Raises VpnError
    for anything else."""
    if not isinstance(doc, dict) or set(doc) != {"names", "relays"}:
        raise VpnError("not a relay list")
    if not isinstance(doc["names"], dict) or not isinstance(doc["relays"], list):
        raise VpnError("not a relay list")
    if not all(isinstance(code, str) and vekrona_vpn.COUNTRY_CODE_RE.fullmatch(code) and isinstance(name, str)
               for code, name in doc["names"].items()):
        raise VpnError("the country names are not two-letter codes with a text each")
    for relay in doc["relays"]:
        vekrona_vpn.validate_relay(relay)
    return doc


def relay_list_from_api(doc: Any) -> dict:
    try:
        locations = doc["locations"]
        names: Dict[str, str] = {}
        relays = []
        for raw in doc["wireguard"]["relays"]:
            if raw.get("active") is not True:
                continue
            country = raw["location"].split("-", 1)[0]
            relay = {"hostname": raw["hostname"], "country": country, "public_key": raw["public_key"],
                     "ipv4": raw["ipv4_addr_in"]}
            try:
                vekrona_vpn.validate_relay(relay)
            except VpnError as err:
                print("vekrona-vpn: ignoring a relay: %s" % err, file=sys.stderr)
                continue
            names[country] = locations[raw["location"]]["country"]
            relays.append(relay)
    except (KeyError, TypeError, AttributeError) as err:
        raise VpnError("the relay list has an unexpected shape (%r)" % (err,))
    return validate_relay_list({"names": names, "relays": relays})


def read_cache(cache: str) -> Optional[dict]:
    """The cached relay list, None when there is none, an error when there is one that cannot be used."""
    try:
        with open(cache) as handle:
            return validate_relay_list(json.load(handle))
    except FileNotFoundError:
        return None
    except (OSError, VpnError, *vekrona_vpn.JSON_ERRORS) as exc:
        raise VpnError("the relay list cache %s is unusable: %s" % (cache, exc))


def cache_is_stale(cache: str) -> bool:
    try:
        return time.time() - os.stat(cache).st_mtime > RELAYS_MAX_AGE_SEC
    except FileNotFoundError:
        return True


def load_relays(cache: str) -> dict:
    """Fetch the relay list and cache it; when the API cannot be reached (the kill switch is armed and the tunnel is down), use
    the cache and say so. No answer and no cache is an error."""
    try:
        value = relay_list_from_api(http_json("GET", "/app/v1/relays"))
    except (ApiError, VpnError) as err:
        cached = read_cache(cache)
        if cached is None:
            raise VpnError("cannot fetch the Mullvad relay list (%s) and there is no cache" % err)
        print("vekrona-vpn: cannot fetch the Mullvad relay list (%s); using the cache" % err, file=sys.stderr)
        return cached
    vekrona_vpn.write_atomic(cache, json.dumps(value) + "\n", vekrona_vpn.PRIVATE_FILE_MODE)
    return value


def current_relays(cache: str) -> dict:
    """The relay list for a command that needs one now: the cache while it is younger than RELAYS_MAX_AGE_SEC (the API is asked for
    the whole list, a megabyte, over a network that may not be the VPN yet), else load_relays. A cache that cannot be used is asked
    for again like an old one."""
    if not cache_is_stale(cache):
        try:
            cached = read_cache(cache)
        except VpnError:
            cached = None
        if cached is not None:
            return cached
    return load_relays(cache)


def select_relay(relay_list: dict, country: str) -> vekrona_vpn.Relay:
    """A random active relay of `country` (a lowercase code)."""
    candidates = [raw for raw in relay_list["relays"] if raw["country"] == country]
    if not candidates:
        raise VpnError("Mullvad has no active relay in %s" % country.upper())
    return vekrona_vpn.Relay(**random.choice(candidates))


def any_relay(relay_list: dict) -> vekrona_vpn.Relay:
    if not relay_list["relays"]:
        raise VpnError("Mullvad's relay list is empty")
    return vekrona_vpn.Relay(**random.choice(relay_list["relays"]))


# ---- The account --------------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class RegisteredDevice:
    id: str
    name: str
    device: vekrona_vpn.Device


def read_account(stdin: Any = None) -> str:
    """The account number from a no-echo prompt on a terminal, or the first line of stdin. Never argv, never disk."""
    stdin = stdin or sys.stdin
    raw = getpass.getpass("Mullvad account number: ") if stdin.isatty() else stdin.readline()
    account = "".join(raw.split())
    if not account.isdigit():
        raise VpnError("the account number must be digits only")
    return account


def public_key_of(private_key: str) -> str:
    return vekrona_vpn.run([WG_TOOL, "pubkey"], input_text=private_key + "\n", secret=True).strip()


def new_key_pair() -> Tuple[str, str]:
    """(private key, public key) from `wg genkey` and `wg pubkey`."""
    private_key = vekrona_vpn.run([WG_TOOL, "genkey"], secret=True).strip()
    return private_key, public_key_of(private_key)


def api_token(account: str) -> str:
    try:
        return http_json("POST", "/auth/v1/token", body={"account_number": account})["access_token"]
    except ApiError as err:
        raise VpnError("Mullvad refused the account: %s" % err)
    except (KeyError, TypeError):
        raise VpnError("Mullvad's token answer has no access_token")


def list_devices(token: str) -> List[Any]:
    """The devices of the account as Mullvad lists them (id, name, pubkey, ...)."""
    try:
        return http_json("GET", "/accounts/v1/devices", token=token)
    except ApiError as err:
        raise VpnError("cannot list the devices of the account: %s" % err)


def max_devices_message(token: str) -> str:
    try:
        listing = ", ".join(str(device.get("name")) for device in list_devices(token))
    except (VpnError, AttributeError, TypeError) as err:
        listing = "the list could not be read (%s)" % err
    return ("the account already has the maximum number of devices (%s); nothing was removed. Remove one at "
            "https://mullvad.net/account and try again" % listing)


def with_prefix(address: str, prefix: int) -> str:
    return address if "/" in address else "%s/%d" % (address, prefix)


def register_device(token: str, private_key: str, public_key: str) -> RegisteredDevice:
    try:
        doc = http_json("POST", "/accounts/v1/devices", body={"pubkey": public_key, "hijack_dns": False}, token=token,
                        expect=(201,))
        return RegisteredDevice(doc["id"], doc["name"], vekrona_vpn.Device(
            private_key, with_prefix(doc["ipv4_address"], ipaddress.IPV4LENGTH), with_prefix(doc["ipv6_address"], ipaddress.IPV6LENGTH)))
    except ApiError as err:
        if MAX_DEVICES_REACHED in err.code:
            raise VpnError(max_devices_message(token))
        raise VpnError("Mullvad refused the new device: %s" % err)
    except (KeyError, TypeError):
        raise VpnError("Mullvad's device answer lacks id, name or addresses")


def revoke_device(token: str, device_id: str) -> None:
    try:
        http_json("DELETE", "/accounts/v1/devices/%s" % urllib.parse.quote(device_id, safe=""), token=token, expect=(204,))
    except ApiError as err:
        raise VpnError("cannot remove the device again: %s" % err)
