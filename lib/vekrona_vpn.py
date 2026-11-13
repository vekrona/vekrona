"""What bin/vekrona-vpn (runs as the user), libexec/vekrona-vpn-apply (runs as root) and their tests share: the WireGuard
configuration (parsed, checked, rendered), the connection ids, the kill switch rules, the NetworkManager calls, the request
the user hands to root, and the JSON the shell reads.

Every number and name that two sides must agree on is defined once here: the fwmark that NetworkManager puts on the tunnel's
own packets is the one the kill switch lets through to the endpoint, and the interface name is the one the kill switch
accepts."""
import base64
import contextlib
import fcntl
import ipaddress
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import time
from dataclasses import dataclass
from functools import cached_property
from typing import Callable, Dict, FrozenSet, Iterator, List, Optional, Sequence, Tuple, TypeGuard

import vekrona_cli
import vekrona_countries

# The layouts that change independently: the output of `status` and `list` (what the shell reads, described by vpn-output.json), the
# state file the helper publishes (state.json, which the tmpfiles entry creates too), and the request the client hands to the helper.
# Each has its own number, raised only when its own shape changes.
OUTPUT_SCHEMA = 2
STATE_SCHEMA = 1
REQUEST_SCHEMA = 1

# Who may read what: a file only its owner can read (a key, a request), one anyone can read (the state and the receipt the shell
# and the client look at), and the same for the directories that hold them.
PRIVATE_FILE_MODE = 0o600
PUBLIC_FILE_MODE = 0o644
PRIVATE_DIR_MODE = 0o700
PUBLIC_DIR_MODE = 0o755

# The interface of the tunnel in use. One tunnel is up at a time, and every connection names this interface.
INTERFACE = "vvpn0"
# NetworkManager names a connection and its interface after the file it imports, and an interface name has 15 characters at most,
# so every configuration is imported under this one name and renamed afterwards. It is not INTERFACE: NetworkManager may bring a
# profile it has just been given up at once, and under the name of the tunnel in use that would replace the tunnel. The change that
# follows the import gives the connection its id and INTERFACE.
IMPORT_NAME = "vvpn-import"
CONF_FILE_NAME = IMPORT_NAME + ".conf"
# The fwmark of the tunnel's own (encrypted) packets. NetworkManager and nft both read a number as hex, and nmcli reads even a bare
# "51820" as hex (0x51820, not 0xca6c), so both get the explicit 0x literal WG_FWMARK_HEX.
WG_FWMARK = 0xCA6C
WG_FWMARK_HEX = "0x%x" % WG_FWMARK

ID_PREFIX = "vekrona-vpn/"
VENDOR_MULLVAD = "mullvad"
VENDOR_PROTON = "proton"
VENDOR_OTHER = "other"
VENDOR_LABELS = {VENDOR_MULLVAD: "Mullvad", VENDOR_PROTON: "Proton VPN", VENDOR_OTHER: "Other"}
# The last segment of the id of a connection that vekrona generates for Proton (vekrona-vpn/proton/<CC or FREE>/signed-in). Only an
# import of `proton` before WP3 has another last segment, and such a connection is never replaced by a connect.
PROTON_GENERATED_NAME = "signed-in"
IMPORT_VENDORS = (VENDOR_OTHER,)
# The vendors whose countries come from a catalog that the vendor's API answers (a cache, no configurations): the country is the choice.
CATALOG_VENDORS = (VENDOR_MULLVAD, VENDOR_PROTON)

RUN_DIR = "/run/vekrona-vpn"
APPLY_UNIT = "vekrona-vpn-apply@%s.service"
LOCK_NAME = "lock"  # in the user's directory (user_dir) and in RUN_DIR: one operation at a time, per user and for the machine
TOR_USER = "toranon"
GETENT_NOT_FOUND = 2  # the status of getent when the key is not in the database

MAX_CONF_BYTES = 16 * 1024
MAX_REQUEST_BYTES = 1024 * 1024
MAX_FILES = 32
MAX_NAME_CHARS = 64
MAX_DETAIL_CHARS = 200  # of a tool's message that an error repeats
MAX_RECEIPT_FAILURE_CHARS = 500  # of the line the helper leaves for the client when an operation failed
WG_KEY_BYTES = 32
MAX_PORT = 65535
MAX_KEEPALIVE_SEC = 65535  # PersistentKeepalive is a 16-bit number of seconds
MIN_MTU, MAX_MTU = 576, 9216  # wg-quick's bounds: IPv6's minimum, and a jumbo frame
# A uid in an instance name is written without a leading zero (one job, one name) and has at most this many digits: the polkit rule
# (a regular expression in a file of its own) says the same, and a test holds the two together.
MAX_UID_DIGITS = 9
UID_PATTERN = r"0|[1-9][0-9]{0,%d}" % (MAX_UID_DIGITS - 1)

# Each wait contains the one it waits for: `nmcli connection up` waits up to NM_UP_WAIT_SEC; a command of the helper may take that
# and a margin; the apply unit lets the helper take as long as the longer of two of those waits (an operation may bring one tunnel
# down and another up) and an import of MAX_FILES files; and bin/vekrona-vpn waits for the unit and a margin. A test reads the
# unit file's TimeoutStartSec (a unit file cannot import this number).
TIMEOUT_MARGIN_SEC = 30
NM_UP_WAIT_SEC = 60
COMMAND_TIMEOUT_SEC = NM_UP_WAIT_SEC + TIMEOUT_MARGIN_SEC
IMPORT_FILE_BUDGET_SEC = 5  # of the helper's time for one imported file: about seven nmcli runs and the file written
APPLY_UNIT_TIMEOUT_SEC = max(2 * NM_UP_WAIT_SEC, MAX_FILES * IMPORT_FILE_BUDGET_SEC)
APPLY_WAIT_SEC = APPLY_UNIT_TIMEOUT_SEC + TIMEOUT_MARGIN_SEC


class VpnError(Exception):
    """A failure to report as one line: the reason, never the content of a file or a key."""


# The keys a person is likely to meet in a wg-quick file; an error may name these and no other word of a file, which may hold anything.
KNOWN_KEYS = frozenset(name.lower() for name in (
    "PostUp", "PreUp", "PostDown", "PreDown", "Table", "SaveConfig", "ListenPort", "FwMark", "Jc", "Jmin", "Jmax", "S1", "S2",
    "H1", "H2", "H3", "H4"))


COUNTRY_CODE_RE = re.compile(r"[a-z]{2}")  # a country as the relay list spells it
# A country in a connection id: a code in capitals, or FREE for Proton's free servers, which belong to no country.
FREE_COUNTRY = "FREE"
CONNECTION_COUNTRY_RE = re.compile(r"[A-Z]{2}|%s" % FREE_COUNTRY)


def label_of(word: str) -> str:
    return word if word.lower() in KNOWN_KEYS else "?"


# ---- The configuration ------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Endpoint:
    address: str
    port: int

    @property
    def family(self) -> int:
        return ipaddress.ip_address(self.address).version

    def __str__(self) -> str:
        return "[%s]:%d" % (self.address, self.port) if ":" in self.address else "%s:%d" % (self.address, self.port)


@dataclass(frozen=True)
class Offer:
    """A country (or Proton's free servers) of a catalog vendor, as `list` shows it: its name, the load of the server that a connect to it
    picks (None when none is known, and for Mullvad, whose relay list has none) and whether that server has IPv6 inside the tunnel."""
    name: str
    load: Optional[int]
    ipv6: bool


@dataclass(frozen=True)
class WgConf:
    private_key: str
    addresses: Tuple[str, ...]
    dns: Tuple[str, ...]
    mtu: Optional[int]
    peer_public_key: str
    preshared_key: Optional[str]
    endpoint: Endpoint
    allowed_ips: Tuple[str, ...]
    keepalive: Optional[int]

    @property
    def has_ipv6(self) -> bool:
        return any(ipaddress.ip_interface(address).version == 6 for address in self.addresses)


INTERFACE_KEYS = {"privatekey": "PrivateKey", "address": "Address", "dns": "DNS", "mtu": "MTU"}
PEER_KEYS = {"publickey": "PublicKey", "presharedkey": "PresharedKey", "endpoint": "Endpoint",
             "allowedips": "AllowedIPs", "persistentkeepalive": "PersistentKeepalive"}
# Keys that wg-quick lets a file repeat, and that hold a comma-separated list.
LIST_KEYS = frozenset({"Address", "DNS", "AllowedIPs"})
SECTIONS = {"[interface]": INTERFACE_KEYS, "[peer]": PEER_KEYS}


# What json.loads raises for text that is no JSON: a ValueError, or a RecursionError for 400000 nested '['.
JSON_ERRORS = (ValueError, RecursionError)


def encode_conf(text: str) -> bytes:
    """The UTF-8 bytes of a configuration that arrived as JSON text, which may hold a lone surrogate (\\ud800): that is no text."""
    try:
        return text.encode("utf-8")
    except UnicodeEncodeError:
        raise VpnError("the text is not valid Unicode")


def decode_conf(raw: bytes) -> str:
    if len(raw) > MAX_CONF_BYTES:
        raise VpnError("the file is larger than %d bytes" % MAX_CONF_BYTES)
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        raise VpnError("the file is not UTF-8 text")


@contextlib.contextmanager
def labelled(label: str) -> Iterator[None]:
    """A VpnError raised inside says which file it is about: "<label>: <reason>". The label is a position or a file name, never
    anything of the file's content."""
    try:
        yield
    except VpnError as exc:
        raise VpnError("%s: %s" % (label, exc))


def _items(values: Sequence[str], key: str) -> List[str]:
    items = [item.strip() for value in values for item in value.split(",")]
    if not all(items):
        raise VpnError("%s has an empty item" % key)
    return items


def wg_key(value: str, key: str) -> str:
    try:
        raw = base64.b64decode(value, validate=True)
    except ValueError:  # binascii.Error, and the ValueError for text that is not ASCII
        raw = b""
    if len(raw) != WG_KEY_BYTES:
        raise VpnError("%s is not a WireGuard key" % key)
    return value


def _integer(value: str, key: str, low: int, high: int) -> int:
    # No more digits than `high` has: int() refuses a string of thousands of digits with an exception of its own.
    if not re.fullmatch(r"[0-9]+", value) or len(value) > len(str(high)) or not low <= int(value) <= high:
        raise VpnError("%s must be a number from %d to %d" % (key, low, high))
    return int(value)


def _keepalive(values: Optional[List[str]]) -> Optional[int]:
    """The interval in seconds, None for no keepalive (absent, 0 or "off")."""
    if values is None or values[0].lower() == "off":
        return None
    return _integer(values[0], "PersistentKeepalive", 0, MAX_KEEPALIVE_SEC) or None


def _unscoped(text: str) -> str:
    """`text`, unless it carries an IPv6 scope id (fe80::1%eth0): that names an interface of the machine that wrote the file, and
    Python keeps whatever follows the '%' (a newline, a ';') in the address that reaches NetworkManager's file and nft's text."""
    if "%" in text:
        raise ValueError("a scope id")
    return text


def parse_endpoint(value: str) -> Endpoint:
    host, colon, port = value.strip().rpartition(":")
    if not colon:
        raise VpnError("Endpoint must be an IP address and a port")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    try:
        address = ipaddress.ip_address(_unscoped(host))
    except ValueError:
        # A name cannot be resolved once the kill switch is armed, and the kill switch lets only the endpoint's address through.
        raise VpnError("Endpoint must be an IP address without a scope id, not a host name")
    if address.is_unspecified or address.is_multicast:
        raise VpnError("Endpoint must be the address of one host")
    return Endpoint(str(address), _integer(port, "the Endpoint port", 1, MAX_PORT))


def parse_conf(text: str) -> WgConf:
    """The one WireGuard peer that `text` (a wg-quick configuration) describes, checked.

    Refused, with a line number or a key name and never the value: a second [Interface] or [Peer], a key that is given twice
    (Address, DNS and AllowedIPs may repeat), a key that is not rendered into the connection (PostUp, Table, ...), a key that is
    no WireGuard key, a DNS entry or Endpoint that is not an IP address (or has an IPv6 scope id), no DNS (every name would go unresolved), and AllowedIPs
    without 0.0.0.0/0 (the kill switch only lets the tunnel carry traffic)."""
    sections: List[Tuple[str, Dict[str, List[str]]]] = []
    for number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            if line.lower() not in SECTIONS:
                raise VpnError("line %d: unknown section" % number)
            sections.append((line.lower(), {}))
            continue
        name, equals, value = line.partition("=")
        if not equals or not sections:
            raise VpnError("line %d: not a section or a key = value" % number)
        header, values = sections[-1]
        key = SECTIONS[header].get(name.strip().lower())
        if key is None:
            raise VpnError("line %d: unsupported key %s in %s" % (number, label_of(name.strip()), header))
        if key in values and key not in LIST_KEYS:
            raise VpnError("line %d: %s is given twice" % (number, key))
        values.setdefault(key, []).append(value.strip())
    interfaces = [values for header, values in sections if header == "[interface]"]
    peers = [values for header, values in sections if header == "[peer]"]
    if len(interfaces) != 1 or len(peers) != 1:
        raise VpnError("the file needs exactly one [Interface] and one [Peer]")
    interface, peer = interfaces[0], peers[0]
    for values, required in ((interface, ("PrivateKey", "Address", "DNS")), (peer, ("PublicKey", "Endpoint", "AllowedIPs"))):
        for key in required:
            if key not in values:
                raise VpnError("%s is missing" % key)
    try:
        addresses = tuple(str(ipaddress.ip_interface(_unscoped(item))) for item in _items(interface["Address"], "Address"))
        dns = tuple(str(ipaddress.ip_address(_unscoped(item))) for item in _items(interface["DNS"], "DNS"))
        allowed = tuple(str(ipaddress.ip_network(_unscoped(item), strict=False)) for item in _items(peer["AllowedIPs"], "AllowedIPs"))
    except ValueError:
        raise VpnError("Address, DNS and AllowedIPs must be IP addresses without a scope id (DNS: no host names)")
    if "0.0.0.0/0" not in allowed:
        raise VpnError("AllowedIPs must contain 0.0.0.0/0: the kill switch lets only the tunnel carry traffic")
    mtu = interface.get("MTU")
    return WgConf(
        private_key=wg_key(interface["PrivateKey"][0], "PrivateKey"),
        addresses=addresses,
        dns=dns,
        mtu=_integer(mtu[0], "MTU", MIN_MTU, MAX_MTU) if mtu else None,
        peer_public_key=wg_key(peer["PublicKey"][0], "PublicKey"),
        preshared_key=wg_key(peer["PresharedKey"][0], "PresharedKey") if "PresharedKey" in peer else None,
        endpoint=parse_endpoint(peer["Endpoint"][0]),
        allowed_ips=allowed,
        keepalive=_keepalive(peer.get("PersistentKeepalive")),
    )


def check_conf(raw: bytes) -> Tuple[str, WgConf]:
    """(text, configuration) of the bytes of a configuration file, or the error that refuses it (size, UTF-8, content)."""
    text = decode_conf(raw)
    return text, parse_conf(text)


# What an import file carries in place of the private key: 32 zero bytes, a key that is public and means nothing. NetworkManager writes
# what it imports into its keyfile, so the real key never goes there; nm_settings_for clears this one in the change that follows.
PLACEHOLDER_KEY = base64.b64encode(bytes(WG_KEY_BYTES)).decode()
# The secret flag of the private key that NetworkManager does not keep in its keyfile (nmcli's "not-saved", 0x2): the key is given
# to `nmcli connection up` on stdin every time.
SECRET_FLAG_NOT_SAVED = 2
# The secret flag of a peer's preshared key that NetworkManager neither stores nor asks for (nmcli's "not-required", 0x4): the key is
# set on the live interface by wg_set_preshared after the activation.
SECRET_FLAG_NOT_REQUIRED = 4
WG_TOOL = "wg"


def render_import_conf(conf: WgConf) -> str:
    """The configuration as `nmcli connection import` reads it, in one fixed shape with only what parse_conf accepts, so that
    nothing of the file the user chose except these fields reaches NetworkManager. Neither key of the file is in it: the private
    key is PLACEHOLDER_KEY, and the preshared key is left out. It carries `Table = off`, which the importer
    turns into wireguard.peer-routes=no. NetworkManager autoconnects a profile it has just been given, and the profile is born with
    autoconnect on and cannot be told otherwise by the import; without routes that tunnel carries nothing. nm_settings_for puts the
    routes back in the same change that turns autoconnect off, so no profile ever has both."""
    lines = ["[Interface]", "PrivateKey = " + PLACEHOLDER_KEY, "Address = " + ", ".join(conf.addresses),
             "DNS = " + ", ".join(conf.dns)]
    if conf.mtu is not None:
        lines.append("MTU = %d" % conf.mtu)
    lines += ["Table = off", "", "[Peer]", "PublicKey = " + conf.peer_public_key]
    lines += ["Endpoint = %s" % conf.endpoint, "AllowedIPs = " + ", ".join(conf.allowed_ips)]
    if conf.keepalive is not None:
        lines.append("PersistentKeepalive = %d" % conf.keepalive)
    return "\n".join(lines) + "\n"


def connection_name(file_name: str) -> str:
    """The name part of a connection id, from the name of the file it was imported from: printable, no '/', 64 characters."""
    stem = os.path.basename(file_name.replace("\\", "/"))
    if stem.lower().endswith(".conf"):
        stem = stem[: -len(".conf")]
    cleaned = "".join(char for char in stem if char.isprintable()).strip()
    return cleaned[:MAX_NAME_CHARS].strip() or "wireguard"


def import_id(vendor: str, file_name: str) -> "ConnectionId":
    """The connection id of a configuration of `vendor` imported from the file `file_name`: the one the helper and the client both give."""
    return ConnectionId(vendor, vekrona_countries.country_in_file_name(file_name), connection_name(file_name))


# ---- Mullvad: the device and the relay ----------------------------------------------------------------------------------

MULLVAD_PORT = 51820
MULLVAD_DNS = ("10.64.0.1", "fc00:bbbb:bbbb:bb01::1")


@dataclass(frozen=True)
class Device:
    private_key: str
    ipv4_address: str
    ipv6_address: str


@dataclass(frozen=True)
class Relay:
    hostname: str
    country: str
    public_key: str
    ipv4: str
    ipv6: str


RELAY_FIELDS = frozenset({"hostname", "country", "public_key", "ipv4", "ipv6"})
DEVICE_FIELDS = frozenset({"private_key", "ipv4_address", "ipv6_address"})


def validate_relay(relay: object) -> Relay:
    """Raise VpnError unless `relay` (a dict of the five Relay fields) is safe to write into a configuration: the relay list
    is the API's word, and its fields land in a file that is read line by line."""
    if not isinstance(relay, dict) or set(relay) != RELAY_FIELDS:
        raise VpnError("a relay has the wrong shape")
    if not all(isinstance(value, str) and value for value in relay.values()):
        raise VpnError("a relay has an empty field")
    if not re.fullmatch(r"[a-z0-9-]+", relay["hostname"]):
        raise VpnError("a relay hostname is not lowercase letters, digits and -")
    if not COUNTRY_CODE_RE.fullmatch(relay["country"]):
        raise VpnError("a relay country is not a two-letter code")
    wg_key(relay["public_key"], "a relay's public_key")
    try:
        ipaddress.IPv4Address(relay["ipv4"])
    except ValueError:
        raise VpnError("a relay's ipv4 is not an IPv4 address")
    try:
        ipaddress.IPv6Address(relay["ipv6"])
    except ValueError:
        raise VpnError("a relay's ipv6 is not an IPv6 address")
    return Relay(**relay)


def validate_device(device: object) -> Device:
    """Raise VpnError unless `device` (a dict of the three Device fields) is a key and two addresses that are safe to write into
    a configuration."""
    if not isinstance(device, dict) or set(device) != DEVICE_FIELDS:
        raise VpnError("a device has the wrong shape")
    if not all(isinstance(value, str) for value in device.values()):
        raise VpnError("a device field is not text")
    wg_key(device["private_key"], "a device's private_key")
    try:
        ipaddress.IPv4Interface(_unscoped(device["ipv4_address"]))
        ipaddress.IPv6Interface(_unscoped(device["ipv6_address"]))
    except ValueError:
        raise VpnError("a device address is not an IPv4 or IPv6 address without a scope id")
    return Device(**device)


KEY_FIELDS = frozenset({"private_key", "preshared_key"})


def validate_keys(doc: object) -> Dict[str, str]:
    """{"private_key", "preshared_key"?} of a request or of the keyring: WireGuard keys and nothing else. Raises VpnError otherwise."""
    if not isinstance(doc, dict) or "private_key" not in doc or not set(doc) <= KEY_FIELDS:
        raise VpnError("the keys have the wrong shape")
    if not all(isinstance(value, str) for value in doc.values()):
        raise VpnError("a key is not text")
    return {name: wg_key(value, name) for name, value in doc.items()}


def mullvad_endpoint(relay: Relay, families: FrozenSet[int]) -> Endpoint:
    """The relay's address in a family the uplink has a default route for: IPv4 when there is one, else IPv6 (an IPv6-only network).
    Neither family reaches the relay, so the connect is refused here, before the kill switch is armed."""
    if 4 in families:
        return Endpoint(relay.ipv4, MULLVAD_PORT)
    if 6 in families:
        return Endpoint(relay.ipv6, MULLVAD_PORT)
    raise VpnError("this network has no default route, so the Mullvad relay cannot be reached")


def mullvad_conf(device: Device, relay: Relay, endpoint: Endpoint) -> WgConf:
    return WgConf(
        private_key=device.private_key,
        addresses=(device.ipv4_address, device.ipv6_address),
        dns=MULLVAD_DNS,
        mtu=None,
        peer_public_key=relay.public_key,
        preshared_key=None,
        endpoint=endpoint,
        allowed_ips=("0.0.0.0/0", "::/0"),
        keepalive=None,
    )


# ---- Connection ids -----------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class ConnectionId:
    """The parts of "vekrona-vpn/<vendor>/<country>/<name>"; the country is a code in capitals or UNKNOWN_COUNTRY."""
    vendor: str
    country: str
    name: str

    def __str__(self) -> str:
        return "%s%s/%s/%s" % (ID_PREFIX, self.vendor, self.country, self.name)


def parse_connection_id(full_id: str) -> ConnectionId:
    """The parts of an id vekrona-vpn made. An id that someone else edited to another shape is vendor "other", country unknown."""
    parts = full_id[len(ID_PREFIX):].split("/", 2)
    if (len(parts) == 3 and parts[0] in VENDOR_LABELS
            and (parts[1] == vekrona_countries.UNKNOWN_COUNTRY or CONNECTION_COUNTRY_RE.fullmatch(parts[1]))):
        return ConnectionId(*parts)
    return ConnectionId(VENDOR_OTHER, vekrona_countries.UNKNOWN_COUNTRY, full_id[len(ID_PREFIX):])


# ---- Running tools ------------------------------------------------------------------------------------------------------

def execute(argv: Sequence[str], *, input_text: Optional[str] = None,
            timeout: int = COMMAND_TIMEOUT_SEC) -> "subprocess.CompletedProcess[str]":
    """A tool run to its end, whatever its status; an error only when it cannot be run or does not end in `timeout` seconds."""
    try:
        # A tool that is given no input gets none (/dev/null), not the caller's stdin: it could read what a person types.
        return subprocess.run(list(argv), input=input_text, stdin=subprocess.DEVNULL if input_text is None else None,
                              capture_output=True, text=True, timeout=timeout, env={**os.environ, "LC_ALL": "C"})
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        # ValueError: an argument with a NUL byte or a lone surrogate, which no program can be given.
        raise VpnError("%s: %s" % (argv[0], exc))


def failure(argv: Sequence[str], result: "subprocess.CompletedProcess[str]", *, secret: bool = False) -> VpnError:
    """The error for a tool that failed: its name and the first line of its message; for a tool that has seen a key
    (secret=True) the message stays out."""
    lines = result.stderr.strip().splitlines()
    detail = "" if secret or not lines else ": " + lines[0][:MAX_DETAIL_CHARS]
    return VpnError("%s failed with status %d%s" % (" ".join(argv[:3]), result.returncode, detail))


def run(argv: Sequence[str], *, input_text: Optional[str] = None, secret: bool = False, timeout: int = COMMAND_TIMEOUT_SEC) -> str:
    """The stdout of a tool that succeeded; a failure is an error (see failure)."""
    result = execute(argv, input_text=input_text, timeout=timeout)
    if result.returncode != 0:
        raise failure(argv, result, secret=secret)
    return result.stdout


@contextlib.contextmanager
def files_reported(action: str) -> Iterator[None]:
    """Whatever file operation inside fails with an OSError is a VpnError that says `action` and why: a person reads one line, not a
    traceback."""
    try:
        yield
    except OSError as exc:
        raise VpnError("cannot %s: %s" % (action, exc.strerror or exc))


def write_atomic(path: str, text: str, mode: int, *, directory_mode: int = PUBLIC_DIR_MODE) -> None:
    """Replace `path` with `text`, never visible half-written, born with `mode`; its directory is made with `directory_mode` if
    missing."""
    with files_reported("write " + path):
        vekrona_cli.write_atomically(path, text, mode=mode, directory_mode=directory_mode)


# ---- NetworkManager -----------------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class Connection:
    uuid: str
    full_id: str
    state: Optional[str]  # NetworkManager's activation state while the connection is active ("activated", "activating", ...)

    @cached_property
    def ident(self) -> ConnectionId:
        return parse_connection_id(self.full_id)

    @property
    def is_active(self) -> bool:
        return self.state is not None

    @cached_property
    def ipv6(self) -> bool:
        """Whether a connect from this connection gets IPv6 inside the tunnel: NetworkManager's copy of the configuration has an IPv6
        address and an allowed range for ::/0. Read when it is asked for (one nmcli call, no secret), so only `list` and `status` pay."""
        addresses, peers = nm_get(self.uuid, ["ipv6.addresses", "wireguard.peers"])
        allowed = [part for token in peers.split() if token.startswith("allowed-ips=") for part in token[len("allowed-ips="):].split(";")]
        return addresses.strip() != "" and "::/0" in allowed

    @property
    def vendor(self) -> str:
        return self.ident.vendor

    @property
    def country(self) -> str:
        return self.ident.country

    @property
    def name(self) -> str:
        return self.ident.name


def split_terse(line: str) -> List[str]:
    """The fields of one line of `nmcli -t`: ':' separates, and '\\:' and '\\\\' are a colon and a backslash in a field."""
    fields, field, escaped = [], "", False
    for char in line:
        if escaped:
            field += char
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append(field)
            field = ""
        else:
            field += char
    return fields + [field]


def nm_listing() -> List[Tuple[str, str, str]]:
    """(uuid, type, name) of every connection NetworkManager has."""
    listing = []
    for line in run(["nmcli", "-t", "-f", "UUID,TYPE,NAME", "connection", "show"]).splitlines():
        fields = split_terse(line)
        if len(fields) != 3:
            raise VpnError("nmcli printed a connection in a shape this tool does not know")
        listing.append((fields[0], fields[1], fields[2]))
    return listing


def nm_connections() -> List[Connection]:
    """Every connection vekrona-vpn made, active or not."""
    states = {}
    for line in run(["nmcli", "-t", "-f", "UUID,STATE", "connection", "show", "--active"]).splitlines():
        fields = split_terse(line)
        if len(fields) != 2:
            raise VpnError("nmcli printed an active connection in a shape this tool does not know")
        states[fields[0]] = fields[1]
    return [Connection(uuid, name, states.get(uuid)) for uuid, kind, name in nm_listing()
            if kind == "wireguard" and name.startswith(ID_PREFIX)]


def nm_unfinished_imports() -> List[str]:
    """The uuids of profiles that an import began and did not finish (the helper was killed between the import and the change that
    names the connection): they hold only the placeholder key, and are named IMPORT_NAME."""
    return [uuid for uuid, kind, name in nm_listing() if kind == "wireguard" and name == IMPORT_NAME]


def nm_get(uuid: str, fields: Sequence[str], *, secrets: bool = False) -> List[str]:
    """The values of `fields` of the connection, one per field (secrets: root only)."""
    argv = ["nmcli"] + (["-s"] if secrets else []) + ["-e", "no", "-g", ",".join(fields), "connection", "show", "uuid", uuid]
    values = run(argv, secret=secrets).split("\n")
    if values and values[-1] == "":
        values.pop()
    if len(values) != len(fields):
        raise VpnError("nmcli answered %d values for %d fields" % (len(values), len(fields)))
    return values


def nm_endpoint(uuid: str) -> Endpoint:
    """Where the connection's one peer is: the address the kill switch must let the handshake reach."""
    (peers,) = nm_get(uuid, ["wireguard.peers"])
    if "," in peers or not peers.strip():
        raise VpnError("the connection must have exactly one peer")
    endpoints = [token[len("endpoint="):] for token in peers.split()[1:] if token.startswith("endpoint=")]
    if len(endpoints) != 1:
        raise VpnError("the connection's peer has no endpoint")
    return parse_endpoint(endpoints[0])


def nm_import(conf_path: str) -> str:
    out = run(["nmcli", "connection", "import", "type", "wireguard", "file", conf_path], secret=True)
    match = re.search(r"\((%s)\)" % UUID_PATTERN, out.lower())
    if not match:
        raise VpnError("nmcli did not say the uuid of the connection it made")
    return match.group(1)


def peer_text(conf: WgConf) -> str:
    """The value of wireguard.peers for the one peer of `conf`, with its preshared key marked not required and the key itself left out
    (wg_set_preshared gives it to the interface at every connect)."""
    attributes = ["endpoint=%s" % conf.endpoint, "allowed-ips=%s" % ";".join(conf.allowed_ips)]
    if conf.keepalive is not None:
        attributes.append("persistent-keepalive=%d" % conf.keepalive)
    attributes.append("preshared-key-flags=%d" % SECRET_FLAG_NOT_REQUIRED)
    return " ".join([conf.peer_public_key, *attributes])


def nm_settings_for(conf: WgConf, full_id: str) -> List[str]:
    """The nmcli property/value arguments, for one `nmcli connection modify`, that turn a connection imported from
    render_import_conf into a vekrona-vpn one: named, on the interface of the tunnel in use, never started by NetworkManager
    itself (and its routes back, which the import left out so that an autoconnect before this change carries nothing), tunnel
    packets marked, all DNS through the tunnel, and no IPv6 of its own when the file has none (an IPv6 default route into a tunnel
    that has no IPv6 address is a black hole; without it the kill switch rejects at once). The private key is cleared and marked
    not saved, and so is the preshared key of the peer, which the import never had: NetworkManager keeps no key of the connection."""
    settings = ["connection.id", full_id, "connection.interface-name", INTERFACE, "connection.autoconnect", "no",
                "wireguard.peer-routes", "yes", "wireguard.fwmark", WG_FWMARK_HEX,
                "ipv4.dns-priority", "-1", "ipv4.dns-search", "~.",
                "wireguard.private-key", "", "wireguard.private-key-flags", str(SECRET_FLAG_NOT_SAVED)]
    if conf.has_ipv6:
        settings += ["ipv6.dns-priority", "-1", "ipv6.dns-search", "~."]
    else:
        settings += ["ipv6.method", "disabled"]
    if conf.preshared_key is not None:
        settings += ["wireguard.peers", peer_text(conf)]
    return settings


PRESHARED_PREFIX = "preshared-key="


def preshared_key_in(peers: str) -> Optional[str]:
    """The preshared key of the one peer of a wireguard.peers value as `nmcli -s` prints it, None when there is none."""
    for token in peers.split()[1:]:
        if token.startswith(PRESHARED_PREFIX):
            return token[len(PRESHARED_PREFIX):]
    return None


def sealed_peers(peers: str) -> str:
    """The one peer of a wireguard.peers value, as `nmcli -s` prints it, with its preshared key taken out and marked not required."""
    public_key, *attributes = peers.split()
    kept = [attribute for attribute in attributes if not attribute.startswith("preshared-key")]
    return " ".join([public_key, *kept, "preshared-key-flags=%d" % SECRET_FLAG_NOT_REQUIRED])


def peer_public_key(peers: str) -> str:
    tokens = peers.split()
    return wg_key(tokens[0] if tokens else "", "the peer's public key")


def nm_seal_settings(uuid: str) -> List[str]:
    """The nmcli property/value arguments that take the keys out of a connection of NetworkManager's keyfile: its private key is
    cleared and marked not saved, and its peer's preshared key, when the peer has one, too. Nothing of them goes on the command line.
    The connection is bound to the tunnel's interface: a profile imported outside vekrona-vpn may name another one, which the kill
    switch (it accepts output on INTERFACE only) would block, so the profile is moved onto INTERFACE."""
    (peers,) = nm_get(uuid, ["wireguard.peers"], secrets=True)
    settings = ["connection.interface-name", INTERFACE,
                "wireguard.private-key", "", "wireguard.private-key-flags", str(SECRET_FLAG_NOT_SAVED)]
    if preshared_key_in(peers) is not None:
        settings += ["wireguard.peers", sealed_peers(peers)]
    return settings


def key_in_keyfile(flags: int) -> bool:
    """The one rule that says a profile still keeps its private key in its keyfile: its secret flags are 0 (nothing is marked not saved).
    Without a secret, that is all that can be read: a profile flagged 0 with no key in it still needs the strip, which marks it."""
    return flags == 0


def key_flags_of(text: str) -> int:
    """The number of NetworkManager's secret flags as nmcli prints them ("0 (none)", "2 (not-saved)"). Zero while the keyfile holds
    the private key, SECRET_FLAG_NOT_SAVED once it is sealed."""
    try:
        return int(text.split()[0])
    except (IndexError, ValueError):
        raise VpnError("nmcli printed the secret flags of a connection in a shape this tool does not know")


def nm_key_flags(uuid: str) -> int:
    (flags,) = nm_get(uuid, ["wireguard.private-key-flags"])
    return key_flags_of(flags)


def nm_modify(uuid: str, settings: Sequence[str]) -> None:
    run(["nmcli", "connection", "modify", "uuid", uuid, *settings])


def nm_up(uuid: str, private_key: str) -> None:
    """Bring the connection up with its private key, which nmcli takes from stdin (passwd-file): NetworkManager keeps no key.
    nmcli's passwd-file cannot name a peer's secret (its parser ends a name at '=', and a base64 public key ends in one), so a
    preshared key is set by wg_set_preshared after this."""
    run(["nmcli", "--wait", str(NM_UP_WAIT_SEC), "connection", "up", "uuid", uuid, "passwd-file", "/dev/stdin"],
        input_text="wireguard.private-key:%s\n" % private_key, secret=True)


def wg_set_preshared(uuid: str, preshared_key: str) -> None:
    """Set the preshared key of the connection's one peer on the live tunnel (INTERFACE). The key goes on stdin of `wg`, never on its
    command line."""
    (peers,) = nm_get(uuid, ["wireguard.peers"])
    run([WG_TOOL, "set", INTERFACE, "peer", peer_public_key(peers), "preshared-key", "/dev/stdin"],
        input_text=preshared_key + "\n", secret=True)


def require_distinct_ids(pairs: Sequence[Tuple["ConnectionId", str]]) -> None:
    """Raise VpnError when two files of one import would make the same connection: the second would replace the first."""
    named: Dict[str, str] = {}
    for ident, file_name in pairs:
        if str(ident) in named:
            raise VpnError("%s and %s would both make the connection %s" % (named[str(ident)], file_name, ident))
        named[str(ident)] = file_name


def require_bound_to_tunnel(uuid: str, full_id: str) -> None:
    """Raise VpnError unless the connection is bound to INTERFACE: the kill switch accepts output on that interface only, and every
    profile vekrona makes is bound to it (import, login and seal set it)."""
    (name,) = nm_get(uuid, ["connection.interface-name"])
    if name != INTERFACE:
        raise VpnError("%s is bound to %s, not %s; vekrona-vpn connects only profiles it imported" % (full_id, name, INTERFACE))


def nm_down(uuid: str) -> None:
    run(["nmcli", "connection", "down", "uuid", uuid])


def nm_delete(uuid: str) -> None:
    run(["nmcli", "connection", "delete", "uuid", uuid])


NM_KEYFILE_DIR = "/etc/NetworkManager/system-connections"
SECRET_LINE_RE = re.compile(r"^(private-key|preshared-key)=", re.MULTILINE)


def require_keyfile_without_secrets(uuid: str) -> None:
    """Raise VpnError unless the keyfile of the connection holds neither its private key nor a preshared key. The keyfile is the copy
    that outlives the connection on disk and in snapshots, so this reads it as root and says nothing of what it holds."""
    with files_reported("list " + NM_KEYFILE_DIR):
        names = sorted(os.listdir(NM_KEYFILE_DIR))
    texts = []
    for name in names:
        path = os.path.join(NM_KEYFILE_DIR, name)
        with files_reported("read " + path):
            with open(path) as handle:
                text = handle.read()
        if re.search(r"^uuid=%s$" % uuid, text, re.MULTILINE):
            texts.append(text)
    if not texts:
        raise VpnError("no keyfile of the connection %s was found" % uuid)
    if any(SECRET_LINE_RE.search(text) for text in texts):
        raise VpnError("the keyfile of the connection %s still holds a key" % uuid)


UUID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
UUID_RE = re.compile(UUID_PATTERN)


def is_uuid(value: object) -> TypeGuard[str]:
    return isinstance(value, str) and UUID_RE.fullmatch(value) is not None


def require_uuid(value: object) -> str:
    if not is_uuid(value):
        raise VpnError("not a connection uuid")
    return value


# ---- The kill switch ----------------------------------------------------------------------------------------------------

TABLE_FAMILY = "inet"
TABLE_NAME = "vekrona-vpn"
TABLE = "%s %s" % (TABLE_FAMILY, TABLE_NAME)
TAILSCALE_INTERFACE = "tailscale0"
TAILNET_V4 = "100.64.0.0/10"
TAILNET_V6 = "fd7a:115c:a1e0::/48"
# tailscaled marks its own packets (control, DERP, UDP 41641) 0x80000 under the mask 0xff0000: they build the tunnel Tailscale
# gives its peers, so they leave by the physical interface. Since Linux 5.17 CAP_NET_RAW may set SO_MARK, so the mark alone is no
# proof of tailscaled; the accept also requires uid 0.
TAILSCALE_MARK = "meta mark & 0x00ff0000 == 0x00080000"
LAN_V4 = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16"
LAN_V6 = "fe80::/10, fc00::/7"
REJECT = "counter reject with icmpx type admin-prohibited"
# Plain DNS and DNS over TLS/QUIC: a resolver of the network (or one that tailscaled forwards to) must not see the names.
DNS_PORTS = "{ 53, 853 }"
MATCH_DNS = "meta l4proto { tcp, udp } th dport %s" % DNS_PORTS
HOOK_PRIORITY = -10
SYNCTHING_DISCOVERY_PORT = 21027
SYNCTHING_DISCOVERY_V6 = "ff12::8384"
LIMITED_BROADCAST_V4 = "255.255.255.255"
MULTICAST_V4 = "224.0.0.0/4"
MULTICAST_V6 = "ff00::/8"
LINK_LOCAL_MULTICAST_V6 = "ff02::/16"  # where MLD reports go
ROOT_UID = 0
ON_LINK_HOP_LIMIT = 255  # of neighbour discovery: a router decrements it, so a packet that arrives with 255 was sent on this link
DHCP_V4_CLIENT_PORT, DHCP_V4_SERVER_PORT = 68, 67
DHCP_V6_CLIENT_PORT, DHCP_V6_SERVER_PORT = 546, 547


def _tailscale_rules() -> List[str]:
    """Only the tailnet's own addresses leave by tailscale0: an exit node selected again would be a way around the VPN."""
    return [
        'oifname "%s" ip daddr %s accept' % (TAILSCALE_INTERFACE, TAILNET_V4),
        'oifname "%s" ip6 daddr %s accept' % (TAILSCALE_INTERFACE, TAILNET_V6),
        'oifname "%s" %s' % (TAILSCALE_INTERFACE, REJECT),
    ]


def _local_network_rules() -> List[str]:
    """The local network, but not its DNS server."""
    return [
        "%s %s" % (MATCH_DNS, REJECT),
        "ip daddr { %s } accept" % LAN_V4,
        "ip6 daddr { %s } accept" % LAN_V6,
    ]


def output_rules(tor_uid: Optional[int]) -> List[str]:
    """The output chain (this machine's own packets), first match wins."""
    rules = ['oifname "lo" accept'] + _tailscale_rules() + [
        # tailscaled's packets keep the physical path, but never to the local network, to multicast, or to a DNS port (MagicDNS
        # forwarding would otherwise ask the network's resolver outside the tunnel). DNS over HTTPS to a public resolver cannot
        # be told from the control plane and DERP, which use port 443 too: docs/vpn.md, "Tailscale and DNS".
        "%s ip daddr { %s, %s } %s" % (TAILSCALE_MARK, LAN_V4, MULTICAST_V4, REJECT),
        "%s ip6 daddr { %s, %s } %s" % (TAILSCALE_MARK, LAN_V6, MULTICAST_V6, REJECT),
        "%s %s %s" % (TAILSCALE_MARK, MATCH_DNS, REJECT),
        "%s meta skuid %d counter accept" % (TAILSCALE_MARK, ROOT_UID),
        'oifname "%s" accept' % INTERFACE,
    ]
    if tor_uid is not None:
        rules.append("meta skuid %d counter accept" % tor_uid)
    rules += [
        "ct direction reply accept",
        # DHCP, neighbour discovery (on-link by definition, so the hop limit keeps a routed copy out) and MLD reports (hop limit 1).
        "udp sport %d udp dport %d accept" % (DHCP_V4_CLIENT_PORT, DHCP_V4_SERVER_PORT),
        "udp sport %d udp dport %d accept" % (DHCP_V6_CLIENT_PORT, DHCP_V6_SERVER_PORT),
        "ip6 hoplimit %d icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept" % ON_LINK_HOP_LIMIT,
        "icmpv6 type { mld-listener-report, mld2-listener-report } ip6 daddr %s accept" % LINK_LOCAL_MULTICAST_V6,
        # The handshake and the tunnel's encrypted packets, which carry the fwmark: the one thing that leaves by the physical
        # interface. Any other program that reached the endpoint would be outside the tunnel.
        "meta mark %s ip daddr . udp dport @endpoint4 accept" % WG_FWMARK_HEX,
        "meta mark %s ip6 daddr . udp dport @endpoint6 accept" % WG_FWMARK_HEX,
    ] + _local_network_rules() + [
        # Syncthing's local discovery: a broadcast to the subnet is in LAN_V4, these two are not.
        "udp dport %d ip daddr %s accept" % (SYNCTHING_DISCOVERY_PORT, LIMITED_BROADCAST_V4),
        "udp dport %d ip6 daddr %s accept" % (SYNCTHING_DISCOVERY_PORT, SYNCTHING_DISCOVERY_V6),
        REJECT,
    ]
    return rules


def forward_rules() -> List[str]:
    """The forward chain (packets this machine routes for others, such as a VM on libvirt's NAT), first match wins. The tunnel,
    the tailnet and the local network follow the output chain's policy; the rest is rejected. Accepting here ends only this
    chain, so firewalld's and libvirt's own forward rules still apply."""
    return ["ct direction reply accept", 'oifname "%s" accept' % INTERFACE] + _tailscale_rules() + _local_network_rules() + [REJECT]


def _endpoint_set(name: str, address_type: str, endpoint: Optional[Endpoint], version: int) -> List[str]:
    lines = ["set %s {" % name, "  type %s . inet_service" % address_type]
    if endpoint is not None and endpoint.family == version:
        lines.append("  elements = { %s . %d }" % (endpoint.address, endpoint.port))
    return lines + ["}"]


def render_killswitch(endpoint: Optional[Endpoint], tor_uid: Optional[int]) -> str:
    """The nft file that arms the kill switch. It declares, deletes and fills the table in one transaction, so loading it over
    a table that exists swaps the rules with no instant at which nothing is blocked."""
    body = _endpoint_set("endpoint4", "ipv4_addr", endpoint, 4) + _endpoint_set("endpoint6", "ipv6_addr", endpoint, 6)
    for hook, rules in (("output", output_rules(tor_uid)), ("forward", forward_rules())):
        body += ["chain %s {" % hook, "  type filter hook %s priority %d; policy accept;" % (hook, HOOK_PRIORITY)]
        body += ["  " + rule for rule in rules] + ["}"]
    return "\n".join(["table %s" % TABLE, "delete table %s" % TABLE, "table %s {" % TABLE]
                     + ["  " + line for line in body] + ["}"]) + "\n"


def render_disarm() -> str:
    """Declaring the table first makes the delete succeed when the table is already gone."""
    return "table %s\ndelete table %s\n" % (TABLE, TABLE)


def require_kill_switch() -> None:
    """Raise VpnError unless the kill switch's table is in the kernel now (whatever state.json says: something else may have
    flushed the ruleset)."""
    try:
        run(["nft", "list", "table", TABLE_FAMILY, TABLE_NAME])
    except VpnError as exc:
        raise VpnError("the kill switch is not loaded, so the tunnel stays down (%s)" % exc)


def lookup_tor_uid() -> Optional[int]:
    """The uid of the system tor user, or None when tor is not installed (nft refuses the name of a user that does not exist,
    and the whole table would fail to load, so the rule takes a number and exists only when there is one)."""
    argv = ["getent", "passwd", TOR_USER]
    result = execute(argv)
    if result.returncode == GETENT_NOT_FOUND:
        return None
    if result.returncode != 0:
        raise failure(argv, result)
    fields = result.stdout.split(":")
    if len(fields) < 3 or not fields[2].isdigit():
        raise VpnError("getent passwd %s printed a line in a shape this tool does not know" % TOR_USER)
    return int(fields[2])


# ---- The uplink ---------------------------------------------------------------------------------------------------------

LOOPBACK = "lo"


def default_devices(listing: str) -> List[str]:
    """The devices of the default routes in `ip route` output: the one of a `default` route and of each `nexthop` of a multipath one. A
    route of another type (unreachable, blackhole, prohibit) does not forward, and its nexthops are none of the uplink's; the loopback is
    never an uplink."""
    devices = []
    forwarding = False
    for line in listing.splitlines():
        words = line.split()
        if not words:
            continue
        if words[0] != "nexthop":
            forwarding = words[0] == "default"  # a route's own line: `default` forwards, the other route types do not
        if forwarding:
            devices += [device for key, device in zip(words, words[1:]) if key == "dev" and device != LOOPBACK]
    return devices


# The switch of IPv6 for all interfaces: 0 when the kernel runs IPv6, 1 when it is switched off.
IPV6_DISABLED_SYSCTL = "/proc/sys/net/ipv6/conf/all/disable_ipv6"


def ipv6_enabled() -> bool:
    """Whether this machine runs IPv6. A kernel without IPv6 has no such switch (it is absent), and a switched-off one says 1: neither has
    an IPv6 uplink, so `ip -6` is not asked (on such a machine it has no routes to report, or fails)."""
    try:
        with open(IPV6_DISABLED_SYSCTL) as handle:
            return handle.read().strip() == "0"
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise VpnError("cannot read %s: %s" % (IPV6_DISABLED_SYSCTL, exc.strerror))


def uplink_families() -> FrozenSet[int]:
    """The IP families (4, 6) that the main table has a default route for on a device other than INTERFACE: the uplink. The tunnel's
    own default route is on INTERFACE while it is up, so it does not count. An endpoint is reachable only in one of these families."""
    families = set()
    for family in (4, 6):
        if family == 6 and not ipv6_enabled():
            continue
        listing = run(["ip", "-%d" % family, "route", "show", "table", "main", "default"])
        if any(device != INTERFACE for device in default_devices(listing)):
            families.add(family)
    return frozenset(families)


def require_route(endpoint: Endpoint, families: FrozenSet[int], vendor: str) -> None:
    """Raise VpnError unless the uplink has a default route in the endpoint's family: a handshake to an address of another family never
    leaves, and the kill switch would hold the tunnel down with no reason shown. Proton has no IPv6 endpoint, so its message says so."""
    if endpoint.family in families:
        return
    if vendor == VENDOR_PROTON:
        raise VpnError("Proton servers are reachable over IPv4 only, and this network has no IPv4 route")
    if vendor == VENDOR_MULLVAD:
        raise VpnError("the Mullvad relay %s is IPv%d, and this network has no IPv%d route: connect to the country again (connect mullvad CC), "
                       "which takes a relay address this network can reach" % (endpoint, endpoint.family, endpoint.family))
    raise VpnError("the endpoint %s is IPv%d, and this network has no IPv%d route" % (endpoint, endpoint.family, endpoint.family))


# ---- Caches -------------------------------------------------------------------------------------------------------------

def read_cache(path: str, validate: Callable[[object], dict]) -> Optional[dict]:
    """The document the cache at `path` holds, checked by `validate`; None when there is no cache, an error when there is one that
    cannot be used."""
    try:
        with open(path) as handle:
            return validate(json.load(handle))
    except FileNotFoundError:
        return None
    except (OSError, VpnError, *JSON_ERRORS) as exc:
        raise VpnError("the cache %s is unusable: %s" % (path, exc))


def write_cache(path: str, value: dict) -> None:
    write_atomic(path, json.dumps(value) + "\n", PRIVATE_FILE_MODE)


def cache_age_sec(path: str) -> float:
    """Seconds since the cache at `path` was written; FileNotFoundError when there is none."""
    return time.time() - os.stat(path).st_mtime


def cache_is_stale(path: str, max_age_sec: int) -> bool:
    try:
        return cache_age_sec(path) > max_age_sec
    except FileNotFoundError:
        return True


# ---- State and requests -------------------------------------------------------------------------------------------------

def run_path(name: str) -> str:
    return os.path.join(RUN_DIR, name)


@dataclass(frozen=True)
class State:
    """What the helper publishes: whether the kill switch is armed, and for which connection (None: for none yet)."""
    armed: bool
    uuid: Optional[str]


DISARMED = State(False, None)


def state_text(state: State) -> str:
    return json.dumps({"schema": STATE_SCHEMA, "armed": state.armed, "uuid": state.uuid}) + "\n"


def read_state() -> State:
    """What the helper published for the shell; no file means nothing was armed since boot."""
    path = run_path("state.json")
    try:
        with open(path) as handle:
            doc = json.load(handle)
    except FileNotFoundError:
        return DISARMED
    except (OSError, *JSON_ERRORS) as exc:
        raise VpnError("cannot read %s: %s" % (path, exc))
    uuid = doc.get("uuid") if isinstance(doc, dict) else None
    if (not isinstance(doc, dict) or doc.get("schema") != STATE_SCHEMA or not isinstance(doc.get("armed"), bool)
            or not (uuid is None or is_uuid(uuid))):
        raise VpnError("%s is not a state this tool knows" % path)
    return State(doc["armed"], uuid)


OPS = ("import", "login", "connect", "off", "forget", "seal")
INSTANCE_RE = re.compile(r"(%s)-(%s)" % ("|".join(OPS), UID_PATTERN))


def instance_name(op: str, uid: int) -> str:
    return "%s-%d" % (op, uid)


def parse_instance(instance: str) -> Tuple[str, int]:
    """(op, uid) of an instance name of vekrona-vpn-apply@.service, or an error: the name comes from whoever may start units."""
    match = INSTANCE_RE.fullmatch(instance)
    if not match:
        raise VpnError("not an operation of vekrona-vpn")
    return match.group(1), int(match.group(2))


USER_RUN_DIR = "/run/user"


def user_dir(uid: int) -> str:
    return os.path.join(USER_RUN_DIR, str(uid), "vekrona-vpn")


def request_path(uid: int) -> str:
    return os.path.join(user_dir(uid), REQUEST_NAME)


def write_request(uid: int, doc: dict) -> None:
    """Hand `doc` to the helper: a file in the user's own runtime directory, which only the user and root can enter."""
    write_atomic(request_path(uid), json.dumps({"schema": REQUEST_SCHEMA, **doc}), PRIVATE_FILE_MODE, directory_mode=PRIVATE_DIR_MODE)


def remove_if_present(path: str) -> None:
    """Removes the file at `path`; a file that is not there is removed already."""
    with files_reported("remove " + path):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def remove_request(uid: int) -> None:
    remove_if_present(request_path(uid))


def sealed_name(uid: int) -> str:
    return "%d.sealed" % uid


def sealed_path(uid: int) -> str:
    """Where the helper leaves the keys of `seal`'s export for user `uid`: next to the user's receipt, in the helper's directory. The
    user reads the file (it is theirs, mode 0600, in tmpfs) and cannot remove it, so the helper removes it: the strip that follows
    the export does, and so does the start of the next operation of the user (remove_sealed), whatever ended the seal."""
    return os.path.join(served_dir(), sealed_name(uid))


def open_served_dir(create: bool) -> int:
    """A descriptor of the receipts' directory, opened without following a link and checked to belong to the helper and to be writable
    by no other user. Names in it are then opened relative to the descriptor."""
    path = served_dir()
    with files_reported("open " + path):
        if create:
            os.makedirs(path, mode=PUBLIC_DIR_MODE, exist_ok=True)
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    info = os.fstat(fd)
    if info.st_uid != os.geteuid() or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        os.close(fd)
        raise VpnError("%s is not a directory of the helper alone" % path)
    return fd


def write_sealed(uid: int, entries: List[dict]) -> None:
    """Leave the keys of the export for user `uid`: a new file, created relative to the checked directory with O_EXCL and O_NOFOLLOW,
    mode 0600 and owned by the user."""
    with files_reported("write " + sealed_path(uid)):
        dir_fd = open_served_dir(create=True)
        try:
            _unlink_sealed(uid, dir_fd)
            fd = os.open(sealed_name(uid), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, PRIVATE_FILE_MODE,
                         dir_fd=dir_fd)
        finally:
            os.close(dir_fd)
        with os.fdopen(fd, "w") as handle:
            os.fchown(handle.fileno(), uid, pwd.getpwuid(uid).pw_gid)
            handle.write(json.dumps(entries))


def _unlink_sealed(uid: int, dir_fd: int) -> None:
    try:
        os.unlink(sealed_name(uid), dir_fd=dir_fd)
    except FileNotFoundError:
        pass


def remove_sealed(uid: int) -> None:
    """Remove the export of user `uid`, if one was left: the user cannot, the directory is the helper's."""
    if not os.path.isdir(served_dir()):
        return
    dir_fd = open_served_dir(create=False)
    try:
        with files_reported("remove " + sealed_path(uid)):
            _unlink_sealed(uid, dir_fd)
    finally:
        os.close(dir_fd)


NONCE_BYTES = 16
NONCE_RE = re.compile(r"[0-9a-f]{%d}" % (2 * NONCE_BYTES))


def require_nonce(value: object) -> str:
    """`value` if it is the nonce of a request, else an error."""
    if not isinstance(value, str) or not NONCE_RE.fullmatch(value):
        raise VpnError("the request holds no nonce")
    return value


@dataclass(frozen=True)
class Receipt:
    """What the helper left for the request with `nonce`: the one line it failed with, None when it succeeded."""
    nonce: str
    failure: Optional[str]


def served_dir() -> str:
    """The helper's receipts, and the export of `seal`: root's directory, which the users read and cannot write."""
    return os.path.join(RUN_DIR, "served")


def served_path(uid: int) -> str:
    return os.path.join(served_dir(), str(uid))


def record_receipt(uid: int, receipt: Receipt) -> None:
    """The helper's receipt for `uid`, in a root-owned file anyone can read: the nonce of the request it has just served, and the
    failure line when the operation failed. The client reports this line, so a failure reaches the person who asked for it and not
    whatever an earlier run left in the journal."""
    failure = "" if receipt.failure is None else " ".join(receipt.failure.split())[:MAX_RECEIPT_FAILURE_CHARS] + "\n"
    write_atomic(served_path(uid), receipt.nonce + "\n" + failure, PUBLIC_FILE_MODE)


def receipt_of(uid: int, nonce: str) -> Optional[Receipt]:
    """The receipt for the request with `nonce`; None when the helper has left none for it (the last one is an earlier request's,
    or there is none)."""
    try:
        with open(served_path(uid)) as handle:
            text = handle.read()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise VpnError("cannot read %s: %s" % (served_path(uid), exc.strerror))
    served, _, failure = text.partition("\n")
    return Receipt(nonce, failure.strip() or None) if served.strip() == nonce else None


def require_served(uid: int, op: str, nonce: str) -> None:
    """After `systemctl start` returned: an error unless the helper served this call's request. The lock lives only as long as the
    client, so a client that was interrupted while its job ran leaves the job behind, and the next call's start merges into it:
    the helper never reads the new request, yet systemctl succeeds."""
    if receipt_of(uid, nonce) is None:
        raise VpnError("another vekrona-vpn %s was still running; try again" % op)


@contextlib.contextmanager
def exclusive_lock(directory: str, directory_mode: int, name: str = LOCK_NAME) -> Iterator[None]:
    """Hold the lock file `name` of `directory` (made if missing) until the block ends, waiting for whoever holds it now."""
    with files_reported("take the lock in " + directory):
        os.makedirs(directory, mode=directory_mode, exist_ok=True)
        fd = os.open(os.path.join(directory, name), os.O_WRONLY | os.O_CREAT | os.O_CLOEXEC, PRIVATE_FILE_MODE)
    with os.fdopen(fd, "w") as lock:
        with files_reported("take the lock in " + directory):
            fcntl.flock(lock, fcntl.LOCK_EX)
        yield


@contextlib.contextmanager
def user_lock(uid: int) -> Iterator[None]:
    """The user's lock: held while a request is handed to the helper, and across several hand-overs that must not interleave with
    another call's (seal). Whoever asks for root work queues here; `status` and `list` never come here."""
    with exclusive_lock(user_dir(uid), PRIVATE_DIR_MODE):
        yield


PROTON_LOCK_NAME = "proton.lock"


@contextlib.contextmanager
def proton_lock(uid: int) -> Iterator[None]:
    """The lock of the Proton session: held while a call of Proton may refresh the session, so that two of them (a connect and the
    renewal) never refresh with the same refresh token. Its own file: the user's lock is taken by the operations of the helper inside it."""
    with exclusive_lock(user_dir(uid), PRIVATE_DIR_MODE, PROTON_LOCK_NAME):
        yield


@contextlib.contextmanager
def hand_over(uid: int, doc: Optional[dict]) -> Iterator[str]:
    """Hand `doc` (None: the operation takes none) and a fresh nonce to the helper as the request, and take it back afterwards. The
    caller holds user_lock. The nonce is what the caller gives to require_served. The request is one file for every operation, and the
    helper's unit is named after the operation alone, so two calls that overlapped (the popout, the launcher, a terminal) would hand
    over each other's request or merge into one job."""
    nonce = secrets.token_hex(NONCE_BYTES)
    write_request(uid, {**(doc or {}), "nonce": nonce})
    try:
        yield nonce
    finally:
        remove_request(uid)


@contextlib.contextmanager
def handed_over(uid: int, doc: Optional[dict]) -> Iterator[str]:
    """user_lock and hand_over together: one operation of the helper at a time, for one request."""
    with user_lock(uid), hand_over(uid, doc) as nonce:
        yield nonce


REQUEST_NAME = "request.json"


def open_user_dir(uid: int) -> int:
    """A descriptor of the user's runtime directory, opened without following a link and checked to be a directory of `uid` that no
    other user can write. Names in it are then opened relative to the descriptor, so a link planted in the path cannot redirect them."""
    path = user_dir(uid)
    with files_reported("open " + path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    info = os.fstat(fd)
    if info.st_uid != uid or info.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        os.close(fd)
        raise VpnError("the request directory is not owned by user %d alone" % uid)
    return fd


def read_request(uid: int) -> dict:
    """The request of user `uid`, read as root: its directory is checked (open_user_dir), the file is opened relative to it without
    following a link, and taken only if it is a regular file of that user and small. No error repeats what the file holds."""
    dir_fd = open_user_dir(uid)
    try:
        fd = os.open(REQUEST_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC, dir_fd=dir_fd)
    except OSError as exc:
        raise VpnError("cannot open the request: %s" % exc.strerror)
    finally:
        os.close(dir_fd)
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise VpnError("the request is not a regular file")
        if info.st_uid != uid:
            raise VpnError("the request is not owned by user %d" % uid)
        if info.st_size > MAX_REQUEST_BYTES:
            raise VpnError("the request is larger than %d bytes" % MAX_REQUEST_BYTES)
        raw = handle.read(MAX_REQUEST_BYTES + 1)
    if len(raw) > MAX_REQUEST_BYTES:
        raise VpnError("the request is larger than %d bytes" % MAX_REQUEST_BYTES)
    try:
        doc = json.loads(raw)
    except JSON_ERRORS:
        raise VpnError("the request is not JSON")
    if not isinstance(doc, dict) or doc.get("schema") != REQUEST_SCHEMA:
        raise VpnError("the request is not in the layout this tool knows")
    return doc


# ---- What the shell reads -----------------------------------------------------------------------------------------------

def active_connection(connections: Sequence[Connection], state: State) -> Optional[Connection]:
    """The connection in use: the active one, else (armed, tunnel down) the one the kill switch was armed for."""
    for connection in connections:
        if connection.state in ("activated", "activating"):
            return connection
    return next((connection for connection in connections if state.armed and connection.uuid == state.uuid), None)


def status_json(connections: Sequence[Connection], state: State, proton: dict) -> dict:
    current = active_connection(connections, state)
    tunnel = {"activated": "up", "activating": "activating"}.get(current.state if current else None, "down")
    return {
        "schema": OUTPUT_SCHEMA,
        "armed": state.armed,
        "tunnel": tunnel,
        "connection": None if current is None else {
            "uuid": current.uuid, "vendor": current.vendor, "country": current.country, "name": current.name,
            "ipv6": current.ipv6},
        "mullvad": {"logged_in": any(connection.vendor == VENDOR_MULLVAD for connection in connections)},
        "proton": proton,
    }


def list_json(connections: Sequence[Connection], offers: Dict[str, Dict[str, Offer]]) -> dict:
    """The vendors with their countries. The catalog vendors' come from their offers (vendor -> code -> Offer) and hold no
    configurations: the country is the choice, and its load and IPv6 are the server's. The others are the countries of the configurations
    imported, whose load is None: each configuration says whether it has IPv6."""
    vendors = []
    for vendor in VENDOR_LABELS:
        countries: Dict[str, dict] = {}
        if vendor in CATALOG_VENDORS:
            for code, offer in offers[vendor].items():
                countries[code.upper()] = {"code": code.upper(), "name": offer.name, "configs": [], "load": offer.load, "ipv6": offer.ipv6}
        else:
            for connection in connections:
                if connection.vendor != vendor:
                    continue
                code = connection.country
                entry = countries.setdefault(code, {"code": code, "name": vekrona_countries.UNKNOWN_COUNTRY_NAME if code == vekrona_countries.UNKNOWN_COUNTRY
                                                    else vekrona_countries.display_name(code.lower(), {}), "configs": [], "load": None, "ipv6": None})
                entry["configs"].append({"uuid": connection.uuid, "name": connection.name,
                                         "ipv6": connection.ipv6})
        for entry in countries.values():
            entry["configs"].sort(key=lambda config: config["name"].casefold())
        vendors.append({"id": vendor, "label": VENDOR_LABELS[vendor],
                        "countries": sorted(countries.values(), key=lambda entry: entry["name"].casefold())})
    return {"schema": OUTPUT_SCHEMA, "vendors": vendors}
