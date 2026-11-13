"""Proton VPN for vekrona-vpn: the sign-in (a fork that the person completes in the browser), the session, the logical servers and
the certificate that a WireGuard connection needs. Runs as the user, never as the root helper. Neither an error nor a log line
names a token, the fork's selector or a key: the selector is a bearer secret for the session, and it reaches the API only in the
path of the poll.

The WireGuard key of the account is the X25519 key of its Ed25519 seed (SHA-512 of the seed, clamped), so the seed is the one secret
the keyring keeps for Proton. The certificate binds that key to the session: its fingerprint is checked against the key on every
answer, and a mismatch is an error before anything is connected.

Raw WireGuard only: there is no Proton agent and no kernel or NetworkManager patch. The app version is pinned: Proton refuses versions
below 5.0.0, and one that it no longer accepts must be bumped by hand (TODO.md)."""
import base64
import hashlib
import ipaddress
import re
import secrets
import urllib.parse
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519

import vekrona_api
import vekrona_countries
import vekrona_vpn
from vekrona_api import ApiError
from vekrona_vpn import VpnError

PROTON_API = "https://vpn-api.proton.me"
# The app version every call carries: the one that completes the sign-in fork (see docs/vpn.md). Proton refuses a version below 5.0.0.
APP_VERSION = "android_tv-vpn@5.20.98.0+apk"
API_VERSION = "3"
ACCEPT = "application/vnd.protonmail.v1+json"
REFUSED_VERSION = "5003"
SESSION_ENDED = "10013"
SIGN_IN_URL = "https://account.protonvpn.com/tv"
SIGN_IN_PENDING = "2001"  # the answer of the poll (422) while the person has not entered the code yet
SIGN_IN_TIMEOUT_SEC = 600
SIGN_IN_POLL_SEC = 5
REFRESH_REDIRECT = "http://protonmail.ch"
CERTIFICATE_DURATION = "1440 min"
NETSHIELD_LEVELS = (0, 1, 2)
FREE_TIER = 0
FREE_NAME = "Fastest free server"
# The logical's Features values (Proton's): SecureCore 1, Tor 2, P2P 4, Streaming 8, IPv6 16. IPv6 is inferred by the spike from the free
# servers; the others are Proton's documented values, not verified against the live API (docs/vpn.md, "Server choice"). A P2P or
# Streaming server stays choosable; Secure Core and Tor servers are left out.
IPV6_FEATURE = 16
SECURE_CORE_FEATURE = 1
TOR_FEATURE = 2
# A certificate that has less than this left is not reused: a connect with it would not last the connection.
CERTIFICATE_MIN_LEFT_SEC = 60 * 60
TUNNEL_IPV4 = "10.2.0.2/32"
TUNNEL_IPV6 = "2a07:b944::2:2/128"
DNS_IPV4 = "10.2.0.1"
DNS_IPV6 = "2a07:b944::2:1"
PORT = 51820
SEED_BYTES = 32
LOGICAL_NAME_RE = re.compile(r"[A-Za-z0-9#._+-]{1,64}")
USER_CODE_LEN = 8
USABLE = 1  # the Status of a server or logical that is up


class SessionEnded(VpnError):
    """Proton refused to refresh the session: this machine is signed out there."""

    def __init__(self) -> None:
        super().__init__("the Proton session has ended; sign in again")


class Unreachable(VpnError):
    """Proton could not be reached (no answer at all, as when the kill switch rejects the connection)."""


@dataclass(frozen=True)
class Session:
    uid: str
    access_token: str
    refresh_token: str


@dataclass(frozen=True)
class Choice:
    """The connection a country (or `free`) makes: its id's country token, the logical and the server of it."""
    country: str
    logical: dict
    server: dict


@dataclass(frozen=True)
class Certificate:
    refresh_time: int
    expiration_time: int


# ---- The API ------------------------------------------------------------------------------------------------------------

def _headers(uid: Optional[str], token: Optional[str]) -> Dict[str, str]:
    headers = {"x-pm-appversion": APP_VERSION, "x-pm-apiversion": API_VERSION, "Accept": ACCEPT}
    if uid is not None:
        headers["x-pm-uid"] = uid
    if token is not None:
        headers["Authorization"] = "Bearer " + token
    return headers


def _request(method: str, path: str, *, name: str, uid: Optional[str] = None, token: Optional[str] = None,
             body: Optional[object] = None, expect: Sequence[int] = (200,)) -> Any:
    return vekrona_api.request_json(PROTON_API, method, path, name=name, headers=_headers(uid, token), body=body, expect=expect)


def _refusal(err: ApiError) -> VpnError:
    if err.status is None:
        return Unreachable(str(err))
    if err.code == REFUSED_VERSION:
        return VpnError("Proton no longer accepts this app version; vekrona needs an update")
    return VpnError(str(err))


def _field(doc: Any, key: str) -> Any:
    """The value of `key` of an answer, which must be a JSON object that has it."""
    if not isinstance(doc, dict) or key not in doc:
        raise VpnError("Proton's answer lacks %s" % key)
    return doc[key]


def _int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _text(value: object) -> bool:
    return isinstance(value, str) and value != ""


def session_of_answer(doc: Any) -> Session:
    uid, access, refresh = (_field(doc, key) for key in ("UID", "AccessToken", "RefreshToken"))
    if not (_text(uid) and _text(access) and _text(refresh)):
        raise VpnError("Proton's session answer holds no usable session")
    return Session(uid, access, refresh)


def session_of_item(item: dict) -> Session:
    """The session of the keyring item, which holds exactly its three fields."""
    if set(item) != {"uid", "access_token", "refresh_token"} or not all(_text(item[key]) for key in item):
        raise VpnError("the keyring's Proton session is in a shape this tool does not know")
    return Session(item["uid"], item["access_token"], item["refresh_token"])


def item_of_session(session: Session) -> dict:
    return {"uid": session.uid, "access_token": session.access_token, "refresh_token": session.refresh_token}


def start_fork() -> Tuple[str, str]:
    """(selector, user code) of a new sign-in. The selector is the session's bearer secret: only poll_fork sends it, and it is never
    shown, logged or put in an argument."""
    try:
        doc = _request("GET", "/auth/v4/sessions/forks", name="start the Proton sign-in")
    except ApiError as err:
        raise _refusal(err)
    selector, code = _field(doc, "Selector"), _field(doc, "UserCode")
    if not (_text(selector) and isinstance(code, str) and len(code) == USER_CODE_LEN and code.isascii() and code.isalnum()):
        raise VpnError("Proton's sign-in answer is in a shape this tool does not know")
    return selector, code


def poll_fork(selector: str) -> Optional[Session]:
    """The session once the person has entered the code; None while they have not."""
    try:
        doc = _request("GET", "/auth/v4/sessions/forks/" + urllib.parse.quote(selector, safe=""), name="poll the Proton sign-in")
    except ApiError as err:
        if err.status == 422 and err.code == SIGN_IN_PENDING:
            return None
        raise _refusal(err)
    return session_of_answer(doc)


def await_session(selector: str, *, now: Callable[[], float], pause: Callable[[float], None]) -> Session:
    """Polls the sign-in every SIGN_IN_POLL_SEC until the person has entered the code, and gives up after SIGN_IN_TIMEOUT_SEC. The
    clock and the pause are the caller's, so a test runs the wait without sleeping."""
    deadline = now() + SIGN_IN_TIMEOUT_SEC
    while True:
        session = poll_fork(selector)
        if session is not None:
            return session
        if now() >= deadline:
            raise VpnError("sign-in timed out")
        pause(SIGN_IN_POLL_SEC)


def refresh(session: Session) -> Session:
    """A new session from the refresh token. Proton rotates the refresh token: the caller stores the new session before it uses it."""
    try:
        doc = _request("POST", "/auth/v4/refresh", name="refresh the Proton session", uid=session.uid, body={
            "UID": session.uid, "RefreshToken": session.refresh_token, "ResponseType": "token", "GrantType": "refresh_token",
            "RedirectURI": REFRESH_REDIRECT})
    except ApiError as err:
        if err.status == 422 and err.code == SESSION_ENDED:
            raise SessionEnded()
        raise _refusal(err)
    return session_of_answer(doc)


class Account:
    """The Proton session in use. A call that the API refuses with 401 renews the session once and retries the call once. A renewal
    rotates the refresh token: the new session is stored (`save`) before it is used. When Proton refuses the refresh token (10013), another
    process may have renewed the session with the same token meanwhile: the stored session (`load`) is then adopted when its refresh token
    differs; the same token means the session has ended. The callers hold the Proton lock (vekrona_vpn.proton_lock) around a call."""

    def __init__(self, session: Session, load: Callable[[], Optional[Session]], save: Callable[[Session], None]) -> None:
        self.session = session
        self._load = load
        self._save = save

    def _renewed(self) -> Session:
        sent = self.session
        try:
            renewed = refresh(sent)
        except SessionEnded:
            stored = self._load()
            if stored is None or stored.refresh_token == sent.refresh_token:
                raise
            return stored
        try:
            self._save(renewed)
        except VpnError as exc:
            raise VpnError("Proton renewed the session, but it could not be stored, so the Proton session is lost: sign in again (%s)"
                           % exc) from exc
        return renewed

    def _send(self, method: str, path: str, name: str, body: Optional[object], expect: Sequence[int]) -> Any:
        return _request(method, path, name=name, uid=self.session.uid, token=self.session.access_token, body=body, expect=expect)

    def call(self, method: str, path: str, *, name: str, body: Optional[object] = None, expect: Sequence[int] = (200,)) -> Any:
        try:
            return self._send(method, path, name, body, expect)
        except ApiError as err:
            if err.status != 401:
                raise _refusal(err)
        self.session = self._renewed()
        try:
            return self._send(method, path, name, body, expect)
        except ApiError as err:
            raise _refusal(err)


def plan_of(account: Account) -> Tuple[int, str]:
    """(the tier the account may connect to, the plan's name). The answer's passwords are OpenVPN secrets: they are not read."""
    section = _field(account.call("GET", "/vpn/v2", name="read the Proton plan"), "VPN")
    tier, plan = _field(section, "MaxTier"), _field(section, "PlanName")
    if not (_int(tier) and tier >= FREE_TIER and isinstance(plan, str)):
        raise VpnError("Proton's plan answer is in a shape this tool does not know")
    return tier, plan


def logicals_of(account: Account) -> List[dict]:
    """The logical servers as Proton answers them."""
    logicals = _field(account.call("GET", "/vpn/v1/logicals", name="list the Proton servers"), "LogicalServers")
    if not isinstance(logicals, list):
        raise VpnError("Proton's server list is in a shape this tool does not know")
    return logicals


def loads_of() -> Dict[str, int]:
    """The load, in percent, of each logical server by its id, as Proton answers it. The answer is public: no session is sent."""
    try:
        doc = _request("GET", "/vpn/v1/loads", name="read the Proton server loads")
    except ApiError as err:
        raise _refusal(err)
    logicals = _field(doc, "LogicalServers")
    if not isinstance(logicals, list):
        raise VpnError("Proton's server loads are in a shape this tool does not know")
    loads = {}
    for raw in logicals:
        if not (isinstance(raw, dict) and isinstance(raw.get("ID"), str) and _int(raw.get("Load")) and 0 <= raw["Load"] <= 100):
            raise VpnError("Proton's server loads are in a shape this tool does not know")
        loads[raw["ID"]] = raw["Load"]
    return loads


def validate_loads(doc: object) -> Dict[str, int]:
    """The loads as the cache keeps them: a percent for each logical id."""
    if not isinstance(doc, dict) or not all(isinstance(key, str) and _int(value) and 0 <= value <= 100 for key, value in doc.items()):
        raise VpnError("not a Proton load list")
    return doc


def logout(account: Account) -> None:
    account.call("DELETE", "/auth/v4", name="end the Proton session")


# ---- Keys and the certificate -------------------------------------------------------------------------------------------

def new_seed() -> bytes:
    return secrets.token_bytes(SEED_BYTES)


def seed_of_item(item: dict) -> bytes:
    """The seed of the keyring item {"seed": base64}, checked to be the length of an Ed25519 seed."""
    try:
        seed = base64.b64decode(item.get("seed", ""), validate=True)
    except (ValueError, TypeError):
        seed = b""
    if len(seed) != SEED_BYTES:
        raise VpnError("the keyring's Proton key is not a seed")
    return seed


def item_of_seed(seed: bytes) -> dict:
    return {"seed": base64.b64encode(seed).decode()}


def x25519_from_seed(seed: bytes) -> bytes:
    """The X25519 private key of an account's seed: the first 32 bytes of its SHA-512, clamped the way X25519 clamps a scalar."""
    key = bytearray(hashlib.sha512(seed).digest()[:32])
    key[0] &= 248
    key[31] &= 127
    key[31] |= 64
    return bytes(key)


def x25519_public(private: bytes) -> bytes:
    return x25519.X25519PrivateKey.from_private_bytes(private).public_key().public_bytes_raw()


def private_key_text(seed: bytes) -> str:
    """The WireGuard private key of the seed, base64: what a connection gives NetworkManager."""
    return base64.b64encode(x25519_from_seed(seed)).decode()


def fingerprint(seed: bytes) -> str:
    """The fingerprint of the seed's X25519 public key, as Proton's certificate answers name it: base64 of its SHA-512."""
    return base64.b64encode(hashlib.sha512(x25519_public(x25519_from_seed(seed))).digest()).decode()


def ed25519_public_pem(seed: bytes) -> str:
    key = ed25519.Ed25519PrivateKey.from_private_bytes(seed).public_key()
    return key.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()


def certificate(account: Account, seed: bytes, netshield: int) -> Certificate:
    """A session certificate for the key of `seed`, with the NetShield level given. Its RefreshTime is when a connection with it needs a
    new one; an answer for another key is an error."""
    body = {"ClientPublicKey": ed25519_public_pem(seed), "Duration": CERTIFICATE_DURATION,
            "Features": {"NetShieldLevel": netshield, "RandomNAT": False, "SplitTCP": False, "PortForwarding": False}}
    doc = account.call("POST", "/vpn/v1/certificate", name="request a Proton certificate", body=body)
    if _field(doc, "ClientKeyFingerprint") != fingerprint(seed):
        raise VpnError("Proton's certificate is for another key")
    refresh_time, expiration_time = _field(doc, "RefreshTime"), _field(doc, "ExpirationTime")
    if not (_int(refresh_time) and _int(expiration_time)):
        raise VpnError("Proton's certificate has no usable RefreshTime or ExpirationTime")
    return Certificate(refresh_time, expiration_time)


# ---- The catalog: the logical servers the account may connect to, as the cache keeps them -------------------------------

# A logical server's id is optional: a catalog written before the loads has none, and its countries have no load (None).
LOGICAL_FIELDS = frozenset({"name", "country", "entry_country", "tier", "features", "score", "status", "servers"})
SERVER_FIELDS = frozenset({"entry_ip", "public_key", "status"})
CATALOG_FIELDS = frozenset({"plan", "max_tier", "logicals", "certificate"})
CERTIFICATE_FIELDS = frozenset({"refresh_time", "expiration_time", "netshield"})


def validate_server(doc: object) -> dict:
    if not isinstance(doc, dict) or set(doc) != SERVER_FIELDS:
        raise VpnError("a server has the wrong shape")
    if not isinstance(doc["entry_ip"], str):
        raise VpnError("a server's entry_ip is not an IP address")
    try:
        ipaddress.ip_address(doc["entry_ip"])
    except ValueError:
        raise VpnError("a server's entry_ip is not an IP address")
    if not isinstance(doc["public_key"], str):
        raise VpnError("a server's public_key is not text")
    vekrona_vpn.wg_key(doc["public_key"], "a server's public_key")
    if not _int(doc["status"]):
        raise VpnError("a server's status is not a number")
    return doc


def validate_logical(doc: object) -> dict:
    """A logical server as the cache keeps it. Its name lands in a connection id and in a connection name, so it is a plain name. Its id
    is Proton's, and is what the loads are matched by; a cache from before the loads has none."""
    if not isinstance(doc, dict) or set(doc) - {"id"} != LOGICAL_FIELDS:
        raise VpnError("a logical server has the wrong shape")
    if "id" in doc and not (isinstance(doc["id"], str) and doc["id"] != ""):
        raise VpnError("a logical server's id is not text")
    if not (isinstance(doc["name"], str) and LOGICAL_NAME_RE.fullmatch(doc["name"])):
        raise VpnError("a logical server's name is not a plain name")
    for field in ("country", "entry_country"):
        if not (isinstance(doc[field], str) and vekrona_vpn.CONNECTION_COUNTRY_RE.fullmatch(doc[field]) and doc[field] != vekrona_vpn.FREE_COUNTRY):
            raise VpnError("a logical server's %s is not a two-letter code" % field.replace("_", " "))
    if not all(_int(doc[field]) for field in ("tier", "features", "status")):
        raise VpnError("a logical server's tier, features or status is not a number")
    if not (isinstance(doc["score"], (int, float)) and not isinstance(doc["score"], bool)):
        raise VpnError("a logical server's score is not a number")
    if not isinstance(doc["servers"], list):
        raise VpnError("a logical server's servers are not a list")
    for server in doc["servers"]:
        validate_server(server)
    return doc


def validate_certificate(doc: object) -> Optional[dict]:
    """The certificate the cache records for the connections (its times are public; the key is not kept), None when there is none."""
    if doc is None:
        return None
    if not isinstance(doc, dict) or set(doc) != CERTIFICATE_FIELDS:
        raise VpnError("a recorded certificate has the wrong shape")
    if not all(_int(doc[field]) for field in CERTIFICATE_FIELDS) or doc["netshield"] not in NETSHIELD_LEVELS:
        raise VpnError("a recorded certificate has a value that is not a number or a NetShield level")
    return doc


def validate_catalog(doc: object) -> dict:
    """The catalog as the cache keeps it: the plan, the highest tier of the account, the logical servers and the certificate in use."""
    if not isinstance(doc, dict) or set(doc) != CATALOG_FIELDS:
        raise VpnError("not a Proton catalog")
    if not (isinstance(doc["plan"], str) and _int(doc["max_tier"]) and doc["max_tier"] >= FREE_TIER and isinstance(doc["logicals"], list)):
        raise VpnError("not a Proton catalog")
    for logical in doc["logicals"]:
        validate_logical(logical)
    validate_certificate(doc["certificate"])
    return doc


def logical_of_answer(raw: object) -> dict:
    """A logical server as the cache keeps it, from Proton's answer. Raises VpnError (the answer has a field the tool does not know)."""
    try:
        servers = [{"entry_ip": server["EntryIP"], "public_key": server["X25519PublicKey"], "status": server["Status"]}
                   for server in raw["Servers"]]
        return validate_logical({"id": raw["ID"], "name": raw["Name"], "country": raw["ExitCountry"], "entry_country": raw["EntryCountry"], "tier": raw["Tier"],
                                 "features": raw["Features"], "score": raw["Score"], "status": raw["Status"], "servers": servers})
    except (KeyError, TypeError, AttributeError) as err:
        raise VpnError("a logical server has an unexpected shape (%r)" % (err,))


def catalog_from_answers(plan: str, max_tier: int, raws: Sequence[object]) -> Tuple[dict, List[str]]:
    """(the catalog, one reason for each logical server it leaves out): a server that does not fit is said, not used."""
    logicals, left_out = [], []
    for position, raw in enumerate(raws, 1):
        try:
            logicals.append(logical_of_answer(raw))
        except VpnError as err:
            left_out.append("logical server %d (%s)" % (position, err))
    return validate_catalog({"plan": plan, "max_tier": max_tier, "logicals": logicals, "certificate": None}), left_out


def usable(catalog: dict) -> List[dict]:
    """The logical servers the account may connect to now: up, within its tier, with a server that is up. Secure Core servers (the entry
    is in another country than the exit, or the SecureCore feature is set) and Tor servers are left out: the choice is a country's exit."""
    return [logical for logical in catalog["logicals"]
            if logical["status"] == USABLE and logical["tier"] <= catalog["max_tier"]
            and logical["entry_country"] == logical["country"] and not logical["features"] & (SECURE_CORE_FEATURE | TOR_FEATURE)
            and any(server["status"] == USABLE for server in logical["servers"])]


def reusable_certificate(catalog: dict, netshield: int, now: float) -> Optional[Certificate]:
    """The certificate the catalog records when it is for `netshield` and has more than CERTIFICATE_MIN_LEFT_SEC left: a connect can use it
    without asking Proton, which a connect while the kill switch blocks the network cannot do."""
    recorded = catalog["certificate"]
    if recorded is None or recorded["netshield"] != netshield or recorded["expiration_time"] - now <= CERTIFICATE_MIN_LEFT_SEC:
        return None
    return Certificate(recorded["refresh_time"], recorded["expiration_time"])


def has_ipv6(logical: dict) -> bool:
    return bool(logical["features"] & IPV6_FEATURE)


def countries_of(catalog: dict, loads: Dict[str, int]) -> Dict[str, vekrona_vpn.Offer]:
    """The choices of the account (code -> Offer, the codes in lower case as the relay lists spell them): `free` for the free plan's
    fastest server, else each country with a usable server. What a choice shows is the server that a connect to it picks (choose):
    its load, from `loads` by logical id, and whether that server has IPv6 (the shell labels a choice without it "IPv4 only")."""
    servers = usable(catalog)
    if catalog["max_tier"] == FREE_TIER:
        queries = [vekrona_vpn.FREE_COUNTRY] if any(logical["tier"] == FREE_TIER for logical in servers) else []
    else:
        queries = sorted({logical["country"] for logical in servers})
    offers = {}
    for query in queries:
        choice = choose(catalog, query)
        ipv6 = has_ipv6(choice.logical)
        name = FREE_NAME if query == vekrona_vpn.FREE_COUNTRY else vekrona_countries.display_name(query.lower(), {})
        offers[query.lower()] = vekrona_vpn.Offer(name, loads.get(choice.logical.get("id")), ipv6)
    return offers


def choose(catalog: dict, query: str) -> Choice:
    """The logical and the server of a connection to `query`: a country code or `free`. Among the usable servers the ones with IPv6 come first
    (IPv6 sites do not work through an IPv4-only tunnel), and the lowest score among those wins; only when no server has IPv6 does an
    IPv4-only one serve, and the choice is labelled so (countries_of). The list of countries and a connect both come from here, so they
    never disagree about which server a country is."""
    code = query.upper()
    free = code == vekrona_vpn.FREE_COUNTRY
    if not (free or vekrona_vpn.CONNECTION_COUNTRY_RE.fullmatch(code)):
        raise VpnError("Proton takes a country code (NL) or free, not %r" % query)
    candidates = [logical for logical in usable(catalog)
                  if (logical["tier"] == FREE_TIER if free else logical["country"] == code)]
    if not candidates:
        raise VpnError("Proton has no server for %s on this account" % ("free" if free else code))
    with_ipv6 = [candidate for candidate in candidates if has_ipv6(candidate)]
    logical = min(with_ipv6 or candidates, key=lambda candidate: candidate["score"])
    server = next(server for server in logical["servers"] if server["status"] == USABLE)
    return Choice(code, logical, server)


def conf_text(logical: dict, server: dict, seed: bytes) -> str:
    """The WireGuard configuration of the server, in the shape vekrona_vpn.parse_conf accepts: the tunnel addresses, DNS through the
    tunnel and all traffic through it, and the server's key and address."""
    ipv6 = bool(logical["features"] & IPV6_FEATURE)
    addresses = [TUNNEL_IPV4] + ([TUNNEL_IPV6] if ipv6 else [])
    dns = [DNS_IPV4] + ([DNS_IPV6] if ipv6 else [])
    allowed = ["0.0.0.0/0"] + (["::/0"] if ipv6 else [])
    return "\n".join([
        "[Interface]", "PrivateKey = " + private_key_text(seed), "Address = " + ", ".join(addresses), "DNS = " + ", ".join(dns),
        "", "[Peer]", "PublicKey = " + server["public_key"], "AllowedIPs = " + ", ".join(allowed),
        "Endpoint = %s:%d" % (server["entry_ip"], PORT), ""])
