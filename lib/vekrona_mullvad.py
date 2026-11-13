"""Mullvad for vekrona-vpn: the account API (a new WireGuard device) and the relay list, with its cache. Runs as the user, before
the kill switch is armed or through the tunnel; the root helper never speaks to the network.

Ported from yolobox-network's egress.py."""
import getpass
import ipaddress
import random
import sys
import urllib.parse
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Sequence, Tuple

import vekrona_api
import vekrona_vpn
from vekrona_api import ApiError
from vekrona_vpn import VpnError

MULLVAD_API = "https://api.mullvad.net"
MAX_DEVICES_REACHED = "MAX_DEVICES_REACHED"
# The API is asked again for the relay list when its cache is older than this.
RELAYS_MAX_AGE_SEC = 24 * 60 * 60
WG_TOOL = vekrona_vpn.WG_TOOL


def http_json(method: str, path: str, *, body: Optional[object] = None, token: Optional[str] = None,
              expect: Sequence[int] = (200,)) -> Any:
    """One JSON request to the Mullvad API (see vekrona_api.request_json)."""
    headers = {} if token is None else {"Authorization": "Bearer " + token}
    return vekrona_api.request_json(MULLVAD_API, method, path, name="%s %s" % (method, path), headers=headers, body=body,
                                    expect=expect)


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
                     "ipv4": raw["ipv4_addr_in"], "ipv6": raw["ipv6_addr_in"]}
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


def offers_of(relay_list: dict) -> Dict[str, vekrona_vpn.Offer]:
    """The countries of the relay list as the offers `list` shows: every relay's configuration carries an IPv6 address (the device's), and
    the relay list has no load to show."""
    return {code: vekrona_vpn.Offer(name, None, True) for code, name in relay_list["names"].items()}


# The relay fields of a cache from before the relays had IPv6 addresses.
RELAY_FIELDS_BEFORE_IPV6 = vekrona_vpn.RELAY_FIELDS - {"ipv6"}


def validate_cached_relay_list(doc: object) -> Optional[dict]:
    """The relay list of a cache, or None for a cache from before the relays had IPv6 addresses: that one is stale, so it reads as no
    cache and the next list asks the API for the relays again."""
    relays = doc.get("relays") if isinstance(doc, dict) else None
    if isinstance(relays, list) and any(isinstance(relay, dict) and set(relay) == RELAY_FIELDS_BEFORE_IPV6 for relay in relays):
        return None
    return validate_relay_list(doc)


def read_cache(cache: str) -> Optional[dict]:
    """The cached relay list, None when there is none (or it is stale), an error when there is one that cannot be used."""
    return vekrona_vpn.read_cache(cache, validate_cached_relay_list)


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
    vekrona_vpn.write_cache(cache, value)
    return value


def current_relays(cache: str) -> dict:
    """The relay list for a command that needs one now: the cache while it is younger than RELAYS_MAX_AGE_SEC (the API is asked for
    the whole list, a megabyte, over a network that may not be the VPN yet), else load_relays. A cache that cannot be used is asked
    for again like an old one."""
    if not vekrona_vpn.cache_is_stale(cache, RELAYS_MAX_AGE_SEC):
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
