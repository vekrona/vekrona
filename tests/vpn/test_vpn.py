"""vekrona-vpn: the configuration checks, the kill switch rules, the request the user hands to root, the root helper and the
user's commands, against stub nmcli/nft/systemctl/getent/wg binaries and a local stand-in for Mullvad's API."""

import base64
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(REPO / "lib"))
sys.path.insert(0, str(HERE))

import vekrona_countries as countries  # noqa: E402
import vekrona_mullvad as mullvad  # noqa: E402
import vekrona_proton as proton  # noqa: E402
import vekrona_secrets as secrets  # noqa: E402
import vekrona_vpn as vpn  # noqa: E402
from vpn_stub import ApiFixture, Stubs, unused_port_base  # noqa: E402


def load_script(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


cli = load_script("vekrona_vpn_cli", REPO / "bin" / "vekrona-vpn")
helper = load_script("vekrona_vpn_apply", REPO / "libexec" / "vekrona-vpn-apply")


def key(n):
    return base64.b64encode(bytes([n]) * 32).decode()


KEY_PRIVATE, KEY_PEER, KEY_RELAY, KEY_PUBLIC = key(1), key(2), key(3), key(4)
UUID_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
UUID_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
UUID_NEW = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
UUID_OLD = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
KEY_PSK = key(5)
KEYS = {"private_key": KEY_PRIVATE}
CONFIG_ID = "vekrona-vpn/other/NL/NL-792"
DEVICE_DOC = {"private_key": KEY_PRIVATE, "ipv4_address": "10.66.0.5/32", "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"}
# The fields `nmcli -s -g` reads of a connection that `seal` exports, in the order the helper asks for them.
SEAL_FIELDS = ["wireguard.private-key-flags", "wireguard.private-key", "wireguard.peers", "ipv4.addresses", "ipv6.addresses"]
SECRET_WORD = "SUPERSECRETVALUE"
NONCE = "0123456789abcdef0123456789abcdef"
OTHER_NONCE = "fedcba9876543210fedcba9876543210"

PROTON_CONF = f"""# NetShield = 0
# Moderate NAT = off
[Interface]
PrivateKey = {KEY_PRIVATE}
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = {KEY_PEER}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.9:51820
"""


def conf_without(line_start):
    return "".join(line for line in PROTON_CONF.splitlines(True) if not line.startswith(line_start))


def relay_dict(hostname="nl-ams-wg-001", country="nl", public_key=KEY_RELAY, ipv4="198.51.100.7"):
    return {"hostname": hostname, "country": country, "public_key": public_key, "ipv4": ipv4}


def terse(text):
    return text.replace("\\", "\\\\").replace(":", "\\:")


def index_starting(calls, prefix):
    """The index of the first call whose argv starts with `prefix`."""
    return next(i for i, call in enumerate(calls) if call[: len(prefix)] == prefix)


class ConfTest(unittest.TestCase):
    def test_a_proton_download_is_accepted_and_is_imported_with_the_placeholder_key_and_nothing_else_changed(self):
        conf = vpn.parse_conf(PROTON_CONF)
        self.assertEqual(conf.endpoint, vpn.Endpoint("203.0.113.9", 51820))
        self.assertEqual(conf.dns, ("10.2.0.1",))
        self.assertFalse(conf.has_ipv6)
        rendered = vpn.render_import_conf(conf)
        self.assertIn("PrivateKey = " + vpn.PLACEHOLDER_KEY + "\n", rendered)
        self.assertEqual(vpn.parse_conf(rendered.replace(vpn.PLACEHOLDER_KEY, KEY_PRIVATE).replace("Table = off\n", "")), conf)

    def test_the_keys_of_a_configuration_never_reach_the_import_file(self):
        with_psk = PROTON_CONF.replace("[Peer]\n", "[Peer]\nPresharedKey = %s\n" % KEY_PSK)
        rendered = vpn.render_import_conf(vpn.parse_conf(with_psk))
        self.assertNotIn(KEY_PRIVATE, rendered)
        self.assertNotIn(KEY_PSK, rendered)
        self.assertNotIn("PresharedKey", rendered)
        self.assertEqual(vpn.parse_conf(with_psk).preshared_key, KEY_PSK)

    def test_what_is_not_a_configuration_is_refused(self):
        for text in ("", "   \n\n", "lizard", "\x00\x01\x02", "[Interface]", "[Evil]\nA = b", "PrivateKey = x", "[Peer]\n[Interface]"):
            with self.subTest(text=text), self.assertRaises(vpn.VpnError):
                vpn.parse_conf(text)

    def test_a_key_given_twice_is_refused_but_a_list_may_repeat(self):
        for single in ("PrivateKey", "Endpoint", "PublicKey"):
            doubled = PROTON_CONF.replace(single, "%s = %s\n%s" % (single, key(9) if "Key" in single else "1.2.3.4:5", single), 1)
            with self.subTest(single=single), self.assertRaisesRegex(vpn.VpnError, "given twice"):
                vpn.parse_conf(doubled)
        repeated = PROTON_CONF.replace("Address = 10.2.0.2/32", "Address = 10.2.0.2/32\nAddress = fd00::2/128")
        self.assertEqual(vpn.parse_conf(repeated).addresses, ("10.2.0.2/32", "fd00::2/128"))
        self.assertTrue(vpn.parse_conf(repeated).has_ipv6)

    def test_a_host_name_endpoint_is_refused_because_it_cannot_be_resolved_once_armed(self):
        for endpoint in ("vpn.example.com:51820", "nl.example:1", ":51820", "203.0.113.9", "203.0.113.9:0", "203.0.113.9:70000",
                         "203.0.113.9:port"):
            with self.subTest(endpoint=endpoint), self.assertRaises(vpn.VpnError):
                vpn.parse_conf(PROTON_CONF.replace("203.0.113.9:51820", endpoint))
        self.assertEqual(vpn.parse_conf(PROTON_CONF.replace("203.0.113.9:51820", "[2001:db8::1]:51820")).endpoint,
                         vpn.Endpoint("2001:db8::1", 51820))

    def test_an_ipv6_scope_id_is_refused_wherever_an_address_goes_because_it_would_reach_nft_and_networkmanager(self):
        for scope in ("%eth0", "%x;y", "%"):
            for old, new in (("DNS = 10.2.0.1", "DNS = fe80::1" + scope), ("Address = 10.2.0.2/32", "Address = fe80::2%s/64" % scope),
                             ("AllowedIPs = 0.0.0.0/0, ::/0", "AllowedIPs = 0.0.0.0/0, fe80::%s/64" % scope),
                             ("203.0.113.9:51820", "[fe80::1%s]:51820" % scope)):
                with self.subTest(replacing=old, scope=scope), self.assertRaises(vpn.VpnError):
                    vpn.parse_conf(PROTON_CONF.replace(old, new))

    def test_tunnel_internal_dns_and_a_server_on_the_local_network_are_accepted_but_not_an_endpoint_that_is_no_host(self):
        conf = vpn.parse_conf(PROTON_CONF.replace("DNS = 10.2.0.1", "DNS = 10.2.0.1, fc00:bbbb:bbbb:bb01::1"))
        self.assertEqual(conf.dns, ("10.2.0.1", "fc00:bbbb:bbbb:bb01::1"))
        self.assertEqual(vpn.parse_conf(PROTON_CONF.replace("203.0.113.9", "192.168.1.5")).endpoint, vpn.Endpoint("192.168.1.5", 51820))
        for endpoint in ("0.0.0.0:51820", "[::]:51820", "224.0.0.1:51820", "[ff02::1]:51820"):
            with self.subTest(endpoint=endpoint), self.assertRaises(vpn.VpnError):
                vpn.parse_conf(PROTON_CONF.replace("203.0.113.9:51820", endpoint))

    def test_no_dns_is_refused_because_every_name_would_go_unresolved(self):
        with self.assertRaisesRegex(vpn.VpnError, "DNS is missing"):
            vpn.parse_conf(conf_without("DNS"))
        with self.assertRaises(vpn.VpnError):
            vpn.parse_conf(PROTON_CONF.replace("DNS = 10.2.0.1", "DNS = dns.example.com"))

    def test_a_configuration_without_an_ipv6_address_is_accepted(self):
        self.assertFalse(vpn.parse_conf(PROTON_CONF).has_ipv6)

    def test_allowed_ips_without_the_default_route_are_refused(self):
        with self.assertRaisesRegex(vpn.VpnError, "0.0.0.0/0"):
            vpn.parse_conf(PROTON_CONF.replace("0.0.0.0/0, ::/0", "10.0.0.0/8"))

    def test_keys_that_do_nothing_for_a_connection_are_refused_without_their_value(self):
        for line in ("PostUp = rm -rf %s" % SECRET_WORD, "Table = off", "ListenPort = 1"):
            with self.subTest(line=line), self.assertRaises(vpn.VpnError) as raised:
                vpn.parse_conf(PROTON_CONF + line + "\n")
            self.assertNotIn(SECRET_WORD, str(raised.exception))

    def test_no_error_repeats_a_key_or_a_value_of_the_file(self):
        garbled = (PROTON_CONF.replace(KEY_PRIVATE, SECRET_WORD), PROTON_CONF.replace(KEY_PEER, SECRET_WORD),
                   PROTON_CONF.replace("10.2.0.1", SECRET_WORD), PROTON_CONF.replace("203.0.113.9:51820", SECRET_WORD),
                   PROTON_CONF + "%s = 1\n" % SECRET_WORD, PROTON_CONF + SECRET_WORD + "\n", SECRET_WORD)
        for text in garbled:
            with self.subTest(text=text[-40:]), self.assertRaises(vpn.VpnError) as raised:
                vpn.parse_conf(text)
            self.assertNotIn(SECRET_WORD, str(raised.exception))

    def test_a_second_peer_or_interface_is_refused(self):
        with self.assertRaises(vpn.VpnError):
            vpn.parse_conf(PROTON_CONF + PROTON_CONF[PROTON_CONF.index("[Peer]"):])
        with self.assertRaises(vpn.VpnError):
            vpn.parse_conf(PROTON_CONF[PROTON_CONF.index("[Interface]"):] + PROTON_CONF)

    def test_keys_must_be_32_bytes_of_base64(self):
        for bad in ("", "short", "A" * 43, "!" * 44, base64.b64encode(b"x" * 31).decode(), base64.b64encode(b"x" * 33).decode()):
            with self.subTest(bad=bad), self.assertRaises(vpn.VpnError):
                vpn.parse_conf(PROTON_CONF.replace(KEY_PRIVATE, bad))

    def test_optional_numbers_are_checked(self):
        conf = vpn.parse_conf(PROTON_CONF + "PersistentKeepalive = 25\n")
        self.assertEqual(conf.keepalive, 25)
        self.assertIsNone(vpn.parse_conf(PROTON_CONF + "PersistentKeepalive = 0\n").keepalive)
        for line in ("PersistentKeepalive = -1", "PersistentKeepalive = lots", "PersistentKeepalive = 99999"):
            with self.subTest(line=line), self.assertRaises(vpn.VpnError):
                vpn.parse_conf(PROTON_CONF + line + "\n")
        with self.assertRaises(vpn.VpnError):
            vpn.parse_conf(PROTON_CONF.replace("[Peer]", "MTU = 12\n[Peer]"))

    def test_the_rendered_configuration_holds_only_the_checked_fields(self):
        rendered = vpn.render_import_conf(vpn.parse_conf(PROTON_CONF))
        self.assertNotIn("NetShield", rendered)
        self.assertNotIn("#", rendered)
        self.assertEqual(rendered.count("Table = off"), 1)

    def test_a_file_that_is_not_utf8_or_too_large_is_refused_without_parsing(self):
        with self.assertRaisesRegex(vpn.VpnError, "UTF-8"):
            vpn.decode_conf(b"\xff\xfe[Interface]")
        with self.assertRaisesRegex(vpn.VpnError, "larger"):
            vpn.decode_conf(b"#" * (vpn.MAX_CONF_BYTES + 1))
        self.assertEqual(vpn.decode_conf(b""), "")


class NamesTest(unittest.TestCase):
    def test_the_country_is_the_first_iso_token_of_the_file_name(self):
        for name, code in (("NL-792.conf", "NL"), ("nl-ams-wg-001.conf", "NL"), ("wg-US-FREE-1.conf", "US"), ("mullvad-se-got.conf", "SE")):
            with self.subTest(name=name):
                self.assertEqual(countries.country_in_file_name(name), code)

    def test_a_file_name_without_a_country_is_unknown(self):
        for name in ("", ".conf", "lizard.conf", "nlams.conf", "xx-1.conf", "12.conf", "Zürich.conf", "../../etc/x"):
            with self.subTest(name=name):
                self.assertEqual(countries.country_in_file_name(name), "??")

    def test_a_connection_name_is_printable_has_no_slash_and_is_at_most_64_characters(self):
        self.assertEqual(vpn.connection_name("Zürich-1.conf"), "Zürich-1")
        self.assertEqual(vpn.connection_name("x" * 100 + ".conf"), "x" * vpn.MAX_NAME_CHARS)
        self.assertEqual(vpn.connection_name("a/b.conf"), "b")
        self.assertEqual(vpn.connection_name("bad\x07name\n.conf"), "badname")
        for empty in ("", ".conf", "../", "\x00"):
            with self.subTest(empty=empty):
                self.assertEqual(vpn.connection_name(empty), "wireguard")

    def test_a_connection_id_round_trips_and_a_foreign_one_is_other(self):
        full = str(vpn.ConnectionId("mullvad", "NL", "nl-ams-wg-001"))
        self.assertEqual(vpn.parse_connection_id(full), vpn.ConnectionId("mullvad", "NL", "nl-ams-wg-001"))
        self.assertEqual(vpn.parse_connection_id(str(vpn.ConnectionId("other", "??", "a/b"))), vpn.ConnectionId("other", "??", "a/b"))
        for odd in ("vekrona-vpn/", "vekrona-vpn/weird", "vekrona-vpn/nobody/NL/x", "vekrona-vpn/other/Netherlands/x",
                    "vekrona-vpn/other/nl/x", "vekrona-vpn/other/N1/x", "vekrona-vpn/other/\u212a\u212a/x", "vekrona-vpn/other/\u00c4\u00d6/x"):
            with self.subTest(odd=odd):
                parsed = vpn.parse_connection_id(odd)
                self.assertEqual((parsed.vendor, parsed.country), ("other", "??"))

    def test_a_country_is_resolved_by_code_name_or_unambiguous_start(self):
        available = {"nl": "Netherlands", "se": "Sweden", "ch": "Switzerland"}
        self.assertEqual(countries.resolve_country("NL", available), ("nl", True))
        self.assertEqual(countries.resolve_country("netherlands", available), ("nl", False))
        self.assertEqual(countries.resolve_country("holland", available), ("nl", False))
        self.assertEqual(countries.resolve_country("swe", available), ("se", False))

    def test_a_country_that_is_empty_unknown_ambiguous_or_without_exits_is_an_error(self):
        available = {"nl": "Netherlands", "se": "Sweden", "ch": "Switzerland"}
        for query in ("", "   ", "Atlantis", "sw", "fr", "France", "\x00"):
            with self.subTest(query=query), self.assertRaises(countries.CountryError):
                countries.resolve_country(query, available)
        with self.assertRaises(countries.CountryError):
            countries.resolve_country("nl", {})

    def test_terse_nmcli_fields_split_on_unescaped_colons(self):
        self.assertEqual(vpn.split_terse(r"a\:b:c\\d:"), ["a:b", "c\\d", ""])
        self.assertEqual(vpn.split_terse(""), [""])


class InstanceTest(unittest.TestCase):
    def test_an_instance_is_an_operation_and_a_uid(self):
        for op in vpn.OPS:
            self.assertEqual(vpn.parse_instance(vpn.instance_name(op, 1000)), (op, 1000))

    def test_anything_else_is_refused(self):
        for bad in ("", "../", "connect-;rm", "connect", "connect-", "connect-1000x", "CONNECT-1000", "connect-1000-1", "connect--1",
                    "forget-1000\n", " import-1000", "import-1234567890", "arm-1000", "import-١٢٣", "../import-1000",
                    "import-1000/../x", "connect-01000", "connect-00", "off-007"):
            with self.subTest(bad=bad), self.assertRaises(vpn.VpnError):
                vpn.parse_instance(bad)

    def test_the_state_file_that_exists_from_boot_is_the_one_the_helper_publishes_when_disarmed(self):
        tmpfiles = (REPO / "etc/tmpfiles.d/vekrona-vpn.conf").read_text()
        match = re.search(r"^f /run/vekrona-vpn/state\.json 0644 root root - (\{.*\})$", tmpfiles, re.MULTILINE)
        self.assertIsNotNone(match, "tmpfiles no longer creates state.json")
        self.assertEqual(json.loads(match.group(1)), json.loads(vpn.state_text(vpn.DISARMED)))

    def test_the_polkit_rule_and_the_helper_accept_the_same_instances(self):
        rule = (REPO / "etc/polkit-1/rules.d/50-vekrona-vpn.rules").read_text()
        match = re.search(r"var applies = /\^vekrona-vpn-apply@(.+)\\\.service\$/\.test\(unit\);", rule)
        self.assertIsNotNone(match, "the rule no longer tests an apply instance with a regular expression")
        polkit = re.compile(r"vekrona-vpn-apply@%s\.service" % match.group(1))
        for instance in ("import-1000", "login-0", "connect-1000", "off-1000", "disconnect-1000", "forget-1000", "", "../", "connect-;rm",
                         "connect-1000x", "arm-1000", "import-1234567890", "connect-1000\n", "x/../connect-1000", "connect-01000",
                         "off-00", "off-999999999", "seal-1000", "seal-x"):
            helper_accepts = True
            try:
                vpn.parse_instance(instance)
            except vpn.VpnError:
                helper_accepts = False
            with self.subTest(instance=instance):
                self.assertEqual(polkit.fullmatch("vekrona-vpn-apply@%s.service" % instance) is not None, helper_accepts)

    def rule_code(self, name):
        """A polkit rule without its comments. Polkit's JavaScript cannot be run here (no polkitd, no JavaScript engine in the guest),
        so what the rules grant is read from their text."""
        text = (REPO / "etc/polkit-1/rules.d" / name).read_text()
        return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("//"))

    def test_the_vpn_rule_starts_apply_units_and_nothing_else(self):
        code = self.rule_code("50-vekrona-vpn.rules")
        self.assertEqual(re.findall(r'verb"?\)? == "(\w+)"', code), ["start"])
        self.assertNotIn("tor.service", code)

    def test_the_tor_rule_starts_and_stops_tor_and_nothing_else(self):
        code = self.rule_code("50-vekrona-tor.rules")
        self.assertEqual(re.findall(r'"([^"]*\.service)"', code), ["tor.service"])
        self.assertEqual(re.findall(r'verb == "(\w+)"', code), ["start", "stop"])
        self.assertNotIn("vekrona-vpn", code)


class TimeoutsTest(unittest.TestCase):
    def test_each_wait_contains_the_one_it_waits_for_and_the_unit_allows_what_the_helper_may_take(self):
        unit = (REPO / "etc/systemd/system/vekrona-vpn-apply@.service").read_text()
        match = re.search(r"^TimeoutStartSec=([0-9]+)$", unit, re.MULTILINE)
        self.assertIsNotNone(match, "the apply unit has no TimeoutStartSec")
        self.assertEqual(int(match.group(1)), vpn.APPLY_UNIT_TIMEOUT_SEC)
        self.assertLess(vpn.NM_UP_WAIT_SEC, vpn.COMMAND_TIMEOUT_SEC)
        self.assertLessEqual(vpn.COMMAND_TIMEOUT_SEC, vpn.APPLY_UNIT_TIMEOUT_SEC)
        self.assertLess(vpn.APPLY_UNIT_TIMEOUT_SEC, vpn.APPLY_WAIT_SEC)


class TorUserTest(unittest.TestCase):
    def test_the_tor_user_of_the_shell_scripts_is_the_one_the_kill_switch_exempts(self):
        names = re.findall(r"^VEKRONA_TOR_USER=(\w+)$", (REPO / "lib/tor.sh").read_text(), re.MULTILINE)
        self.assertEqual(names, [vpn.TOR_USER])


class RestoreTest(unittest.TestCase):
    def test_an_item_that_cannot_be_put_back_does_not_stop_the_others_and_is_named(self):
        stored, cleared = [], []

        def store(kind, ident, value):
            if ident == "B":
                raise vpn.VpnError("the keyring refused")
            stored.append(ident)

        previous = [("config-key", "A", {"private_key": "a"}), ("config-key", "B", {"private_key": "b"}), ("config-key", "C", None)]
        with mock.patch.object(secrets, "store", side_effect=store), \
                mock.patch.object(secrets, "clear", side_effect=lambda kind, ident: cleared.append(ident)):
            problem = secrets.restore(previous)
        self.assertEqual((stored, cleared), (["A"], ["C"]))
        self.assertIn("config-key of B: the keyring refused", problem)
        self.assertNotIn("of A", problem)


class KillSwitchTest(unittest.TestCase):
    def rendered(self, endpoint=None, tor_uid=None):
        return vpn.render_killswitch(endpoint, tor_uid)

    def rules(self, text):
        return [line.strip() for line in text.splitlines()]

    def test_the_mark_the_tunnel_uses_is_the_mark_the_kill_switch_lets_through(self):
        settings = vpn.nm_settings_for(vpn.parse_conf(PROTON_CONF), "vekrona-vpn/other/NL/x")
        nm_mark = int(settings[settings.index("wireguard.fwmark") + 1], 16)  # nmcli reads hex, with or without 0x
        self.assertEqual(nm_mark, vpn.WG_FWMARK)
        nft_marks = re.findall(r"meta mark (0x[0-9a-f]+) ip6? daddr", self.rendered())
        self.assertEqual(len(nft_marks), 2)
        for nft_mark in nft_marks:
            self.assertEqual(int(nft_mark, 16), nm_mark)

    def test_the_tunnel_interface_is_accepted_and_has_a_name_the_kernel_allows(self):
        self.assertIn('oifname "%s" accept' % vpn.INTERFACE, self.rules(self.rendered()))
        self.assertLessEqual(len(vpn.INTERFACE), 15)

    def test_the_tor_rule_exists_only_with_a_numeric_uid(self):
        self.assertNotIn("skuid 970", self.rendered())
        self.assertNotIn("toranon", self.rendered(tor_uid=970))
        self.assertIn("meta skuid 970 counter accept", self.rendered(tor_uid=970))
        self.assertEqual(len([line for line in self.rules(self.rendered(tor_uid=970)) if "skuid 970" in line]), 1)

    def test_the_endpoint_lands_only_in_the_set_of_its_family(self):
        v4 = self.rendered(vpn.Endpoint("203.0.113.9", 51820))
        v6 = self.rendered(vpn.Endpoint("2001:db8::1", 443))
        self.assertIn("elements = { 203.0.113.9 . 51820 }", v4)
        self.assertEqual(v4.count("elements"), 1)
        self.assertIn("elements = { 2001:db8::1 . 443 }", v6)
        self.assertEqual(v6.count("elements"), 1)
        self.assertNotIn("elements", self.rendered())

    def chain(self, name, tor_uid=None):
        lines = self.rules(self.rendered(tor_uid=tor_uid))
        start = lines.index("chain %s {" % name)
        return lines[start + 2: lines.index("}", start)]

    def test_everything_unmatched_is_rejected_at_once_not_dropped(self):
        for name in ("output", "forward"):
            with self.subTest(chain=name):
                self.assertEqual(self.chain(name)[-1], "counter reject with icmpx type admin-prohibited")
        self.assertNotIn(" drop", self.rendered())

    def test_forwarded_packets_cannot_leave_around_the_tunnel(self):
        text = self.rendered()
        self.assertIn("chain forward {\n    type filter hook forward priority -10; policy accept;", text)
        forward = self.chain("forward")
        self.assertEqual(forward[:2], ["ct direction reply accept", 'oifname "vvpn0" accept'])
        self.assertNotIn('oifname "lo" accept', forward)

    def test_forwarding_accepts_nothing_that_the_output_chain_does_not(self):
        forward, output = self.chain("forward"), self.chain("output")
        self.assertEqual([rule for rule in forward if rule not in output], [])
        self.assertGreater(len(forward), 2)

    def test_the_rules_of_this_machine_alone_stay_out_of_the_forward_chain(self):
        forward = "\n".join(self.chain("forward", tor_uid=970))
        for fragment in ("skuid", "mark", "@endpoint", "21027", "dport 67", "icmpv6"):
            self.assertNotIn(fragment, forward)

    def test_a_mark_alone_does_not_make_a_packet_tailscaleds(self):
        # Read from the text because a namespace maps uid 0 to the user who runs the test, so no probe can be a packet of uid 0.
        accepts = [rule for rule in self.chain("output") if rule.startswith(vpn.TAILSCALE_MARK) and rule.endswith("accept")]
        self.assertEqual(len(accepts), 1)
        self.assertIn("meta skuid %d " % vpn.ROOT_UID, accepts[0])
        rules = self.chain("output")
        self.assertLess(rules.index(accepts[0]), rules.index('oifname "%s" accept' % vpn.INTERFACE))
        rejects = [rule for rule in rules if rule.startswith(vpn.TAILSCALE_MARK) and rule.endswith(vpn.REJECT)]
        self.assertTrue(rejects)
        for reject in rejects:
            self.assertLess(rules.index(reject), rules.index(accepts[0]))

    def test_dhcp_neighbour_discovery_and_mld_are_let_through(self):
        # Read from the text because no probe can show it: the kernel sends no ICMP error for a broadcast or a multicast destination,
        # so a rejected packet of these looks like an accepted one to a socket (NftTest.test_packets_...).
        text = self.rendered()
        for fragment in ("udp sport 68 udp dport 67", "udp sport 546 udp dport 547", "nd-neighbor-solicit",
                         "mld2-listener-report"):
            self.assertIn(fragment, text)


class NftTest(unittest.TestCase):
    """The rules and their removal, read by the real nft inside a throwaway user and network namespace, so that nothing touches
    the machine's own rules."""

    def setUp(self):
        # Fail, never skip: a check that does not run is a rule nobody has shown nft accepts. The guest has nft and may create a
        # user and a network namespace.
        if shutil.which("nft") is None or shutil.which("unshare") is None:
            self.fail("this test needs nft and unshare")
        probe = subprocess.run(["unshare", "-rn", "true"], capture_output=True, text=True)
        if probe.returncode != 0:
            self.fail("this test needs a user and a network namespace: %s" % probe.stderr.strip())
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.dir = Path(directory.name)

    def write(self, name, text):
        path = self.dir / name
        path.write_text(text)
        return path

    def in_namespace(self, script):
        return subprocess.run(["unshare", "-rn", "sh", "-ec", script], capture_output=True, text=True)

    def test_packets_are_rejected_or_pass_as_the_kill_switch_says(self):
        """Real packets in a namespace of dummy interfaces: eth0 (the network, with a local network on it), vvpn0 (the tunnel) and
        tailscale0. A packet the table rejects fails at once ('no route to host' for TCP, 'not permitted' for UDP; that a TCP packet
        is rejected and not dropped shows in the first, a drop would time out); one it lets through is sent and nothing answers, so
        the socket times out."""
        if shutil.which("ip") is None:
            self.fail("this test needs ip")
        table = self.write("arm.nft", vpn.render_killswitch(vpn.Endpoint("203.0.113.9", 51820), None))
        wanted = {
            "the internet around the tunnel": (("tcp", "203.0.113.50", 443), "rejected"),
            "the internet through the tunnel": (("tcp", "198.51.100.50", 443), "passes"),
            "DNS through the tunnel": (("udp", "198.51.100.50", 53), "passes"),
            "a web server of the local network": (("tcp", "192.168.77.50", 8080), "passes"),
            "the local network's DNS over UDP": (("udp", "192.168.77.50", 53), "rejected"),
            "the local network's DNS over TCP": (("tcp", "192.168.77.50", 53), "rejected"),
            "the local network's DNS over TLS": (("tcp", "192.168.77.50", 853), "rejected"),
            "a node of the tailnet": (("tcp", "100.64.0.9", 22), "passes"),
            "an address outside the tailnet through tailscale0": (("tcp", "198.18.0.1", 443), "rejected"),
            "the handshake to the endpoint": (("udp", "203.0.113.9", 51820, vpn.WG_FWMARK), "passes"),
            "the endpoint's port without the tunnel's mark": (("udp", "203.0.113.9", 51820), "rejected"),
            "another port of the endpoint with the mark": (("udp", "203.0.113.9", 51821, vpn.WG_FWMARK), "rejected"),
            "another host with the mark": (("udp", "203.0.113.50", 51820, vpn.WG_FWMARK), "rejected"),
        }
        result = subprocess.run(
            ["unshare", "-rn", sys.executable, "-c", PROBE_SCRIPT, str(table), json.dumps({name: probe for name, (probe, _) in wanted.items()})],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {name: verdict for name, (_, verdict) in wanted.items()})

    def test_every_variant_passes_nft_check(self):
        endpoints = (None, vpn.Endpoint("203.0.113.9", 51820), vpn.Endpoint("2001:db8::1", 51820))
        variants = [vpn.render_killswitch(endpoint, tor_uid) for endpoint in endpoints for tor_uid in (None, 970)]
        for index, text in enumerate(variants + [vpn.render_disarm()]):
            path = self.write("%d.nft" % index, text)
            checked = subprocess.run(["unshare", "-rn", "nft", "-c", "-f", str(path)], capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, "variant %d: %s" % (index, checked.stderr))

    def test_the_kill_switch_loads_over_itself_and_is_removed_whether_or_not_it_is_loaded(self):
        arm = self.write("arm.nft", vpn.render_killswitch(vpn.Endpoint("203.0.113.9", 51820), None))
        disarm = self.write("disarm.nft", vpn.render_disarm())
        script = "\n".join([
            "nft -f %s" % disarm,  # not loaded yet: removing it still succeeds
            "nft -f %s" % arm,
            "nft -f %s" % arm,  # swapped over a loaded one
            "nft list table %s %s >/dev/null" % (vpn.TABLE_FAMILY, vpn.TABLE_NAME),
            "nft -f %s" % disarm,
            "if nft list table %s %s >/dev/null 2>&1; then echo 'still loaded' >&2; exit 1; fi" % (vpn.TABLE_FAMILY, vpn.TABLE_NAME),
            "nft -f %s" % disarm,  # and again, with nothing loaded
        ])
        result = self.in_namespace(script)
        self.assertEqual(result.returncode, 0, result.stderr)


PROBE_SCRIPT = r"""
import errno, json, socket, subprocess, sys

def ip(*args):
    subprocess.run(["ip", *args], check=True)

ip("link", "set", "lo", "up")
for name, address in (("eth0", "192.168.77.2/24"), ("vvpn0", "10.9.0.2/32"), ("tailscale0", "100.64.0.2/32")):
    ip("link", "add", name, "type", "dummy")
    ip("addr", "add", address, "dev", name)
    ip("link", "set", name, "up")
for destination, device in (("203.0.113.50", "eth0"), ("203.0.113.9", "eth0"), ("198.51.100.50", "vvpn0"),
                            ("100.64.0.9", "tailscale0"), ("198.18.0.1", "tailscale0")):
    ip("route", "add", destination + "/32", "dev", device)
subprocess.run(["nft", "-f", sys.argv[1]], check=True)

def probe(kind, address, port, mark=None):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM if kind == "tcp" else socket.SOCK_DGRAM)
    sock.settimeout(0.5)
    try:
        if mark is not None:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, mark)
        sock.connect((address, port))
        if kind == "udp":
            sock.send(b"x")
            sock.recv(1)
    except socket.timeout:
        return "passes"  # sent, and nothing came back: not even an ICMP error
    except OSError as exc:
        # A TCP connect fails with the ICMP error of the reject; a UDP send fails with EPERM, the verdict of the hook itself.
        return "rejected" if exc.errno in (errno.EHOSTUNREACH, errno.EPERM) else "failed with " + errno.errorcode[exc.errno]
    finally:
        sock.close()
    return "answered"

print(json.dumps({name: probe(*arguments) for name, arguments in json.loads(sys.argv[2]).items()}))
"""


class Sandbox(unittest.TestCase):
    """A scratch /run, a scratch /run/user, stub binaries first on PATH, and a scratch home for the relay cache."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="vekrona-vpn-test-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.stubs = Stubs(self.tmp / "stubs")
        self.uid = os.getuid()
        env = {**self.stubs.env(), "PATH": "%s:%s" % (self.stubs.bin, os.environ["PATH"]),
               "XDG_CACHE_HOME": str(self.tmp / "cache"), "XDG_CONFIG_HOME": str(self.tmp / "config"), "HOME": str(self.tmp / "home")}
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        for name, value in (("RUN_DIR", str(self.tmp / "run" / "vekrona-vpn")), ("USER_RUN_DIR", str(self.tmp / "run" / "user"))):
            patched = mock.patch.object(vpn, name, value)
            patched.start()
            self.addCleanup(patched.stop)
        self.relay_cache = self.tmp / "cache" / "vekrona" / "vpn-relays.json"
        self.keyfiles = self.tmp / "system-connections"
        self.keyfiles.mkdir()
        patched = mock.patch.object(vpn, "NM_KEYFILE_DIR", str(self.keyfiles))
        patched.start()
        self.addCleanup(patched.stop)

    def nm_lists(self, connections, active=()):
        """What nmcli shows: connections [(uuid, id)] (all WireGuard), active [(uuid, state)]."""
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,TYPE,NAME", "connection", "show"],
                          stdout="".join("%s:wireguard:%s\n" % (uuid, terse(full_id)) for uuid, full_id in connections))
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,STATE", "connection", "show", "--active"],
                          stdout="".join("%s:%s\n" % pair for pair in active))

    def nm_imports_as(self, uuid):
        self.stubs.behave("nmcli", ["connection", "import"], stdout="Connection '%s' (%s) successfully added.\n" % (vpn.IMPORT_NAME, uuid))

    def nm_peer_of(self, uuid, endpoint, interface=vpn.INTERFACE):
        """The peer and the interface (the one the profile is bound to) that nmcli answers for the connection `uuid`."""
        self.stubs.behave("nmcli", ["-e", "no", "-g", "wireguard.peers", "connection", "show", "uuid", uuid],
                          stdout="%s allowed-ips=0.0.0.0/0;::/0; endpoint=%s\n" % (KEY_PEER, endpoint))
        self.stubs.behave("nmcli", ["-e", "no", "-g", "connection.interface-name", "connection", "show", "uuid", uuid],
                          stdout="%s\n" % interface)

    def nm_read(self, uuid, fields, values, with_secrets=False):
        """What nmcli answers for `-g FIELDS connection show uuid UUID` (with -s when with_secrets), one line per field."""
        argv = (["-s"] if with_secrets else []) + ["-e", "no", "-g", ",".join(fields), "connection", "show", "uuid", uuid]
        self.stubs.behave("nmcli", argv, stdout="".join(value + "\n" for value in values))

    def keyfile(self, uuid, text=""):
        """The keyfile of NetworkManager for the connection `uuid`: its uuid and `text`."""
        (self.keyfiles / ("%s.nmconnection" % uuid)).write_text("[connection]\nuuid=%s\n%s" % (uuid, text))

    def nmcli_actions(self):
        """The nmcli calls that change something, as [verb, ...]."""
        return [call["argv"] for call in self.stubs.calls("nmcli") if call["argv"][:1] in (["connection"], ["--wait"])]

    def state_file(self):
        return self.tmp / "run" / "vekrona-vpn" / "state.json"

    def state(self):
        return json.loads(self.state_file().read_text())

    def request(self, doc, nonce=NONCE):
        vpn.write_request(self.uid, {**doc, "nonce": nonce})

    def served(self):
        """What the helper recorded as served for this user; None before it served anything."""
        path = Path(vpn.served_path(self.uid))
        return path.read_text().strip() if path.exists() else None


class RequestTest(Sandbox):
    def path(self, uid=None):
        return Path(vpn.request_path(self.uid if uid is None else uid))

    def test_a_request_round_trips_and_is_private(self):
        vpn.write_request(self.uid, {"uuid": UUID_A})
        self.assertEqual(vpn.read_request(self.uid), {"schema": 1, "uuid": UUID_A})
        self.assertEqual(stat.S_IMODE(self.path().stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.path().parent.stat().st_mode), 0o700)
        vpn.remove_request(self.uid)
        vpn.remove_request(self.uid)
        self.assertFalse(self.path().exists())

    def lock_is_held_by_someone(self):
        with open(Path(vpn.user_dir(self.uid)) / vpn.LOCK_NAME, "a") as probe:
            try:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            return False

    def test_a_call_that_hands_over_a_request_holds_the_lock_until_it_has_taken_it_back(self):
        with vpn.handed_over(self.uid, {"uuid": UUID_A}):
            self.assertTrue(self.lock_is_held_by_someone())
            self.assertEqual(vpn.read_request(self.uid)["uuid"], UUID_A)
        self.assertFalse(self.lock_is_held_by_someone())
        self.assertFalse(self.path().exists())

    def test_a_call_that_fails_still_takes_its_request_back_and_frees_the_lock(self):
        with self.assertRaises(ZeroDivisionError), vpn.handed_over(self.uid, {"uuid": UUID_A}):
            1 / 0
        self.assertFalse(self.lock_is_held_by_someone())
        self.assertFalse(self.path().exists())

    def test_an_operation_without_arguments_hands_over_only_its_nonce_and_still_queues(self):
        with vpn.handed_over(self.uid, None) as nonce:
            self.assertTrue(self.lock_is_held_by_someone())
            self.assertEqual(vpn.read_request(self.uid), {"schema": 1, "nonce": nonce})

    def test_every_call_hands_over_a_nonce_of_its_own(self):
        with vpn.handed_over(self.uid, {"uuid": UUID_A}) as first:
            self.assertEqual(vpn.read_request(self.uid)["nonce"], first)
        with vpn.handed_over(self.uid, {"uuid": UUID_A}) as second:
            pass
        self.assertRegex(first, vpn.NONCE_RE)
        self.assertNotEqual(first, second)

    def test_only_a_request_with_a_real_nonce_is_served(self):
        self.assertEqual(vpn.require_nonce(NONCE), NONCE)
        for bad in (None, "", 5, ["x"], NONCE.upper(), NONCE + "0", NONCE[:-1], "../" + NONCE[3:], NONCE + "\n"):
            with self.subTest(bad=bad), self.assertRaises(vpn.VpnError):
                vpn.require_nonce(bad)

    def test_a_call_whose_request_was_not_served_fails_and_one_that_was_passes(self):
        with self.assertRaisesRegex(vpn.VpnError, "another vekrona-vpn connect was still running; try again"):
            vpn.require_served(self.uid, "connect", NONCE)  # nothing served yet
        vpn.record_receipt(self.uid, vpn.Receipt(OTHER_NONCE, None))
        with self.assertRaisesRegex(vpn.VpnError, "another vekrona-vpn connect was still running"):
            vpn.require_served(self.uid, "connect", NONCE)
        vpn.record_receipt(self.uid, vpn.Receipt(NONCE, None))
        vpn.require_served(self.uid, "connect", NONCE)
        self.assertEqual(stat.S_IMODE(Path(vpn.served_path(self.uid)).stat().st_mode), 0o644)

    def test_a_receipt_carries_the_failure_as_one_line_of_the_request_it_belongs_to(self):
        vpn.record_receipt(self.uid, vpn.Receipt(NONCE, "nmcli failed:\n  no\tdevice"))
        self.assertEqual(vpn.receipt_of(self.uid, NONCE), vpn.Receipt(NONCE, "nmcli failed: no device"))
        self.assertIsNone(vpn.receipt_of(self.uid, OTHER_NONCE))
        vpn.record_receipt(self.uid, vpn.Receipt(NONCE, "x" * 10 * vpn.MAX_RECEIPT_FAILURE_CHARS))
        self.assertEqual(len(vpn.receipt_of(self.uid, NONCE).failure), vpn.MAX_RECEIPT_FAILURE_CHARS)
        vpn.record_receipt(self.uid, vpn.Receipt(NONCE, None))
        self.assertEqual(vpn.receipt_of(self.uid, NONCE), vpn.Receipt(NONCE, None))

    def test_a_request_that_cannot_be_written_is_an_error_not_a_traceback(self):
        Path(vpn.USER_RUN_DIR).mkdir(parents=True)
        (Path(vpn.USER_RUN_DIR) / str(self.uid)).write_text("a file where the user's directory belongs")
        with self.assertRaisesRegex(vpn.VpnError, "cannot take the lock"), vpn.handed_over(self.uid, None):
            self.fail("the block must not run without the lock")

    def test_a_missing_request_is_an_error(self):
        with self.assertRaisesRegex(vpn.VpnError, "cannot open"):
            vpn.read_request(self.uid)

    def test_a_link_is_not_followed(self):
        target = self.tmp / "target.json"
        target.write_text(json.dumps({"schema": 1, "uuid": UUID_A}))
        self.path().parent.mkdir(parents=True)
        self.path().symlink_to(target)
        with self.assertRaises(vpn.VpnError):
            vpn.read_request(self.uid)

    def test_a_file_of_another_user_is_refused(self):
        other = self.uid + 1
        self.path(other).parent.mkdir(parents=True)
        self.path(other).write_text(json.dumps({"schema": 1}))
        with self.assertRaisesRegex(vpn.VpnError, "not owned"):
            vpn.read_request(other)

    def test_a_pipe_is_refused_without_blocking(self):
        self.path().parent.mkdir(parents=True)
        os.mkfifo(self.path())
        with self.assertRaisesRegex(vpn.VpnError, "not a regular file"):
            vpn.read_request(self.uid)

    def test_an_oversized_request_is_refused(self):
        self.path().parent.mkdir(parents=True)
        self.path().write_text(" " * (vpn.MAX_REQUEST_BYTES + 1))
        with self.assertRaisesRegex(vpn.VpnError, "larger"):
            vpn.read_request(self.uid)

    def test_a_request_that_is_not_json_or_has_another_layout_is_refused_without_its_content(self):
        self.path().parent.mkdir(parents=True)
        # 500000 nested lists make json.loads raise RecursionError, not ValueError.
        for text in ("", "not json " + SECRET_WORD, "[]", "null", json.dumps({"schema": 2, "x": SECRET_WORD}), json.dumps({"x": 1}),
                     "[" * 500000):
            self.path().write_text(text)
            with self.subTest(text=text[:20]), self.assertRaises(vpn.VpnError) as raised:
                vpn.read_request(self.uid)
            self.assertNotIn(SECRET_WORD, str(raised.exception))


class NetworkManagerTest(Sandbox):
    def test_only_wireguard_connections_made_by_vekrona_vpn_are_listed_with_their_state(self):
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,TYPE,NAME", "connection", "show"], stdout=(
            "%s:wireguard:%s\n%s:wireguard:work-vpn\n%s:ethernet:%s\n" % (
                UUID_A, terse("vekrona-vpn/other/??/a:b"), UUID_B, UUID_OLD, terse("vekrona-vpn/other/??/not-wireguard"))))
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,STATE", "connection", "show", "--active"], stdout="%s:activated\n" % UUID_A)
        found = vpn.nm_connections()
        self.assertEqual([(c.uuid, c.full_id, c.state) for c in found], [(UUID_A, "vekrona-vpn/other/??/a:b", "activated")])

    def test_nmcli_output_in_an_unknown_shape_is_an_error(self):
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,TYPE,NAME", "connection", "show"], stdout="onlyone\n")
        with self.assertRaises(vpn.VpnError):
            vpn.nm_connections()

    def test_a_failing_nmcli_is_an_error_naming_it(self):
        self.stubs.behave("nmcli", ["-t"], rc=8, stderr="Error: NetworkManager is not running.\n")
        with self.assertRaisesRegex(vpn.VpnError, "nmcli.*status 8.*not running"):
            vpn.nm_connections()

    def test_an_argument_no_program_can_be_given_is_an_error_not_a_crash(self):
        for argument in ("\ud800", "a\x00b"):
            with self.subTest(argument=repr(argument)), self.assertRaises(vpn.VpnError):
                vpn.run(["true", argument])

    def test_a_tool_is_given_no_input_unless_it_is_handed_some_and_never_the_callers_stdin(self):
        child = "import sys; sys.path.insert(0, %r); import vekrona_vpn as v; print(repr(v.run(['cat'])), repr(v.run(['cat'], input_text='given')))" % str(REPO / "lib")
        result = subprocess.run([sys.executable, "-B", "-c", child], input="typed by a person", capture_output=True, text=True)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "'' 'given'"), result.stderr)

    def test_a_missing_nmcli_is_an_error(self):
        with mock.patch.dict(os.environ, {"PATH": str(self.tmp)}), self.assertRaisesRegex(vpn.VpnError, "nmcli"):
            vpn.nm_connections()

    def test_the_endpoint_is_read_from_the_peer(self):
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.assertEqual(vpn.nm_endpoint(UUID_A), vpn.Endpoint("203.0.113.9", 51820))
        self.nm_peer_of(UUID_A, "[2001:db8::1]:51820")
        self.assertEqual(vpn.nm_endpoint(UUID_A), vpn.Endpoint("2001:db8::1", 51820))

    def test_an_endpoint_that_is_a_name_or_missing_or_a_second_peer_is_refused(self):
        for answer in ("%s endpoint=vpn.example.com:51820\n" % KEY_PEER, "%s allowed-ips=0.0.0.0/0;\n" % KEY_PEER, "\n",
                       "%s endpoint=1.2.3.4:5,%s endpoint=1.2.3.5:5\n" % (KEY_PEER, KEY_RELAY)):
            self.stubs.behave("nmcli", ["-e", "no", "-g", "wireguard.peers"], stdout=answer)
            with self.subTest(answer=answer), self.assertRaises(vpn.VpnError):
                vpn.nm_endpoint(UUID_A)

    def test_import_returns_the_uuid_nmcli_names_and_keeps_its_complaints_to_itself(self):
        conf = self.tmp / vpn.CONF_FILE_NAME
        conf.write_text("")
        self.nm_imports_as(UUID_A.upper())
        self.assertEqual(vpn.nm_import(conf), UUID_A)
        for stdout in ("done\n", "Connection 'x' (%s) successfully added.\n" % ("-" * 36), "Connection 'x' (%s) added.\n" % UUID_A[:-1]):
            self.stubs.behave("nmcli", ["connection", "import"], stdout=stdout)
            with self.subTest(stdout=stdout), self.assertRaises(vpn.VpnError):
                vpn.nm_import(conf)
        self.stubs.behave("nmcli", ["connection", "import"], rc=1, stderr="Error: bad key %s\n" % SECRET_WORD)
        with self.assertRaises(vpn.VpnError) as raised:
            vpn.nm_import(conf)
        self.assertNotIn(SECRET_WORD, str(raised.exception))

    def test_a_connection_with_ipv6_keeps_ipv6_and_one_without_has_none(self):
        with_v6 = vpn.nm_settings_for(vpn.parse_conf(PROTON_CONF.replace("10.2.0.2/32", "10.2.0.2/32, fd00::2/128")), "id")
        without = vpn.nm_settings_for(vpn.parse_conf(PROTON_CONF), "id")
        self.assertIn("ipv6.dns-search", with_v6)
        self.assertNotIn("ipv6.method", with_v6)
        self.assertEqual(without[without.index("ipv6.method") + 1], "disabled")
        for settings in (with_v6, without):
            self.assertEqual(settings[settings.index("connection.autoconnect") + 1], "no")
            self.assertEqual(settings[settings.index("ipv4.dns-search") + 1], "~.")
            self.assertEqual(settings[settings.index("ipv4.dns-priority") + 1], "-1")

    def test_nm_up_gives_only_the_private_key_on_stdin_and_never_on_the_command_line(self):
        vpn.nm_up(UUID_A, KEY_PRIVATE)
        (call,) = self.stubs.called("nmcli", "--wait")
        self.assertEqual(call["argv"], ["--wait", str(vpn.NM_UP_WAIT_SEC), "connection", "up", "uuid", UUID_A, "passwd-file", "/dev/stdin"])
        self.assertEqual(call["stdin"], "wireguard.private-key:%s\n" % KEY_PRIVATE)

    def test_the_preshared_key_is_set_on_the_tunnel_by_wg_with_the_key_on_stdin_and_never_on_its_command_line(self):
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        vpn.wg_set_preshared(UUID_A, KEY_PSK)
        (call,) = self.stubs.called("wg", "set")
        self.assertEqual(call["argv"], ["set", vpn.INTERFACE, "peer", KEY_PEER, "preshared-key", "/dev/stdin"])
        self.assertEqual(call["stdin"], KEY_PSK + "\n")
        self.assertNotIn(KEY_PSK, json.dumps(self.stubs.argvs()))

    def test_a_peer_is_always_written_whole_because_nmcli_replaces_it(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        with self.assertRaisesRegex(vpn.VpnError, "replaced"):
            vpn.nm_modify(UUID_A, ["wireguard.peers", "%s preshared-key-flags=4" % KEY_PEER])
        vpn.nm_modify(UUID_A, ["wireguard.peers", "%s endpoint=203.0.113.9:51820 allowed-ips=0.0.0.0/0 preshared-key-flags=4" % KEY_PEER])



    def test_a_key_flag_is_a_number_however_nmcli_prints_it(self):
        self.assertEqual(vpn.key_flags_of("0 (none)"), 0)
        self.assertEqual(vpn.key_flags_of("2 (not-saved)"), vpn.SECRET_FLAG_NOT_SAVED)
        for text in ("", "none"):
            with self.subTest(text=text), self.assertRaises(vpn.VpnError):
                vpn.key_flags_of(text)

    def test_the_tor_user_is_found_absent_or_an_error(self):
        self.assertIsNone(vpn.lookup_tor_uid())
        self.stubs.behave("getent", ["passwd", "toranon"], stdout="toranon:x:970:970:Tor:/var/lib/tor:/sbin/nologin\n")
        self.assertEqual(vpn.lookup_tor_uid(), 970)
        self.stubs.behave("getent", ["passwd", "toranon"], stdout="garbage\n")
        with self.assertRaises(vpn.VpnError):
            vpn.lookup_tor_uid()
        self.stubs.behave("getent", ["passwd", "toranon"], rc=1)
        with self.assertRaises(vpn.VpnError):
            vpn.lookup_tor_uid()


NO_PROTON = {"logged_in": False, "netshield": 1, "error": ""}


class ShellJsonTest(unittest.TestCase):
    def conn(self, uuid, full_id, state=None):
        return vpn.Connection(uuid, full_id, state)

    def test_nothing_connected_and_nothing_armed(self):
        status = vpn.status_json([], vpn.DISARMED, NO_PROTON)
        self.assertEqual(status, {"schema": 1, "armed": False, "tunnel": "down", "connection": None, "mullvad": {"logged_in": False},
                                  "proton": NO_PROTON})

    def test_a_proton_sign_in_and_its_netshield_level_are_in_the_status(self):
        proton_status = {"logged_in": True, "netshield": 2, "error": ""}
        self.assertEqual(vpn.status_json([], vpn.DISARMED, proton_status)["proton"], proton_status)

    def test_a_netshield_setting_that_cannot_be_read_is_said_and_leaves_no_level(self):
        unreadable = {"logged_in": True, "netshield": None, "error": "the NetShield level in the settings is not one of 0, 1, 2"}
        self.assertEqual(vpn.status_json([], vpn.DISARMED, unreadable)["proton"], unreadable)

    def test_an_active_connection_is_up_or_activating(self):
        connection = self.conn(UUID_A, "vekrona-vpn/mullvad/NL/nl-ams-wg-001", "activated")
        up = vpn.status_json([connection], vpn.State(True, UUID_A), NO_PROTON)
        self.assertEqual((up["tunnel"], up["armed"], up["mullvad"]), ("up", True, {"logged_in": True}))
        self.assertEqual(up["connection"], {"uuid": UUID_A, "vendor": "mullvad", "country": "NL", "name": "nl-ams-wg-001"})
        activating = self.conn(UUID_A, "vekrona-vpn/other/??/home", "activating")
        self.assertEqual(vpn.status_json([activating], vpn.State(True, UUID_A), NO_PROTON)["tunnel"], "activating")

    def test_armed_with_a_tunnel_that_is_down_still_names_the_connection(self):
        connection = self.conn(UUID_A, "vekrona-vpn/other/NL/NL-792")
        blocked = vpn.status_json([connection, self.conn(UUID_B, "vekrona-vpn/other/??/x")], vpn.State(True, UUID_A), NO_PROTON)
        self.assertEqual((blocked["tunnel"], blocked["connection"]["uuid"]), ("down", UUID_A))
        disarmed = vpn.status_json([connection], vpn.State(False, UUID_A), NO_PROTON)
        self.assertIsNone(disarmed["connection"])

    def test_a_connection_that_was_forgotten_while_armed_is_no_connection(self):
        self.assertIsNone(vpn.status_json([], vpn.State(True, UUID_A), NO_PROTON)["connection"])

    def test_the_list_has_every_vendor_and_the_catalog_vendors_countries_are_their_catalogs_and_have_no_configurations(self):
        connections = [self.conn(UUID_OLD, "vekrona-vpn/other/??/Zürich home"), self.conn(UUID_NEW, "vekrona-vpn/proton/DE/de-1")]
        listing = vpn.list_json(connections, {"mullvad": {"se": "Sweden", "nl": "Netherlands"}, "proton": {"free": "Fastest free server"}})
        self.assertEqual(listing["schema"], 1)
        self.assertEqual([vendor["id"] for vendor in listing["vendors"]], ["mullvad", "proton", "other"])
        mullvad_vendor, proton_vendor, other = listing["vendors"]
        self.assertEqual(mullvad_vendor["countries"], [{"code": "NL", "name": "Netherlands", "configs": []},
                                                       {"code": "SE", "name": "Sweden", "configs": []}])
        # A Proton connection of an earlier install is not a configuration of the list: the catalog is.
        self.assertEqual(proton_vendor["countries"], [{"code": "FREE", "name": "Fastest free server", "configs": []}])
        self.assertEqual(other["countries"], [{"code": "??", "name": "Unknown", "configs": [{"uuid": UUID_OLD, "name": "Zürich home"}]}])
        self.assertEqual(proton_vendor["label"], "Proton VPN")

    def test_an_empty_list_is_three_empty_vendors(self):
        listing = vpn.list_json([], {"mullvad": {}, "proton": {}})
        self.assertEqual([(v["id"], v["countries"]) for v in listing["vendors"]], [("mullvad", []), ("proton", []), ("other", [])])


class HelperTest(Sandbox):
    def apply(self, op):
        helper.apply(vpn.instance_name(op, self.uid))

    def import_request(self, *files, vendor="other"):
        self.request({"vendor": vendor, "files": [{"file": name, "text": text} for name, text in files]})

    def test_arming_lets_the_handshake_through_to_the_endpoint_and_publishes_the_connection(self):
        self.stubs.behave("getent", ["passwd", "toranon"], stdout="toranon:x:970:970::/:/sbin/nologin\n")
        helper.arm(UUID_A, vpn.Endpoint("203.0.113.9", 51820))
        (call,) = self.stubs.called("nft")
        self.assertEqual(call["argv"], ["-f", "-"])
        self.assertEqual(call["stdin"], vpn.render_killswitch(vpn.Endpoint("203.0.113.9", 51820), 970))
        self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": UUID_A})

    def test_a_kill_switch_that_nft_refuses_leaves_the_state_it_found(self):
        for before in (vpn.State(False, None), vpn.State(True, UUID_OLD), None):
            self.stubs.behave("nft", ["-f"], rc=1, stderr="Error: syntax\n")
            self.state_file().unlink(missing_ok=True)
            if before is not None:
                helper.publish(before)
            with self.subTest(before=before), self.assertRaisesRegex(vpn.VpnError, "nft -f - failed"):
                helper.arm(UUID_A, vpn.Endpoint("203.0.113.9", 51820))
            expected = before or vpn.DISARMED
            self.assertEqual(self.state(), {"schema": 1, "armed": expected.armed, "uuid": expected.uuid})

    def test_an_arm_that_cannot_publish_loads_no_table(self):
        helper.publish(vpn.DISARMED)
        with mock.patch.object(helper, "publish", side_effect=vpn.VpnError("disk full")), self.assertRaises(vpn.VpnError):
            helper.arm(UUID_A, vpn.Endpoint("203.0.113.9", 51820))
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertEqual(self.state(), {"schema": 1, "armed": False, "uuid": None})

    def test_a_kill_switch_that_nft_refuses_and_a_state_that_cannot_be_restored_say_both(self):
        helper.publish(vpn.DISARMED)
        self.stubs.behave("nft", ["-f"], rc=1, stderr="Error: syntax\n")
        publish = helper.publish

        def publish_only_the_new_state(state):
            if state.armed is False:
                raise vpn.VpnError("disk full")
            publish(state)

        with mock.patch.object(helper, "publish", publish_only_the_new_state), \
                self.assertRaisesRegex(vpn.VpnError, "syntax.*published again: disk full"):
            helper.arm(UUID_A, vpn.Endpoint("203.0.113.9", 51820))

    def test_disarming_deletes_the_table_and_publishes_it(self):
        helper.publish(vpn.State(True, UUID_A))
        helper.disarm()
        (call,) = self.stubs.called("nft")
        self.assertEqual(call["stdin"], vpn.render_disarm())
        self.assertEqual(self.state(), {"schema": 1, "armed": False, "uuid": None})
        helper.disarm()

    def test_a_disarm_that_cannot_publish_leaves_the_table_and_the_state_where_they_are(self):
        helper.publish(vpn.State(True, UUID_A))
        with mock.patch.object(helper, "publish", side_effect=vpn.VpnError("disk full")), self.assertRaises(vpn.VpnError):
            helper.disarm()
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": UUID_A})

    def test_a_table_that_nft_cannot_delete_is_never_published_as_disarmed(self):
        for before in (vpn.State(True, UUID_A), vpn.State(True, None), None):
            self.stubs.behave("nft", ["-f"], rc=1, stderr="Error: busy\n")
            if before is not None:
                helper.publish(before)
            with self.subTest(before=before), self.assertRaisesRegex(vpn.VpnError, "nft -f - failed"):
                helper.disarm()
            self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": before.uuid if before else None})

    def test_a_table_that_cannot_be_deleted_and_a_state_that_cannot_be_restored_say_both(self):
        helper.publish(vpn.State(True, UUID_A))
        self.stubs.behave("nft", ["-f"], rc=1, stderr="Error: busy\n")
        publish = helper.publish

        def publish_only_the_disarmed_state(state):
            if state.armed:
                raise vpn.VpnError("disk full")
            publish(state)

        with mock.patch.object(helper, "publish", publish_only_the_disarmed_state), \
                self.assertRaisesRegex(vpn.VpnError, "busy.*published again: disk full"):
            helper.disarm()

    def test_an_operation_leaves_a_receipt_with_the_nonce_of_its_request_and_the_line_it_failed_with(self):
        self.request({}, nonce=OTHER_NONCE)
        self.nm_lists([])
        self.apply("off")
        self.assertEqual(vpn.receipt_of(self.uid, OTHER_NONCE), vpn.Receipt(OTHER_NONCE, None))
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,TYPE,NAME", "connection", "show"], rc=1, stderr="Error: NetworkManager is not running.\n")
        self.request({}, nonce=NONCE)
        with self.assertRaises(vpn.VpnError):
            self.apply("off")
        self.assertEqual(vpn.receipt_of(self.uid, NONCE), vpn.Receipt(NONCE, "nmcli -t -f failed with status 1: Error: NetworkManager is not running."))

    def test_a_failure_that_the_receipt_cannot_record_is_reported_with_the_failure(self):
        self.request({}, nonce=NONCE)
        (self.tmp / "run" / "vekrona-vpn").mkdir(parents=True)
        (self.tmp / "run" / "vekrona-vpn" / "served").write_text("a file where the receipts' directory belongs")
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,TYPE,NAME", "connection", "show"], rc=1, stderr="Error: no\n")
        with self.assertRaisesRegex(vpn.VpnError, "nmcli.*failed.*and its receipt could not be written"):
            self.apply("off")

    def test_a_request_without_a_nonce_is_refused_before_anything_is_done(self):
        for doc in ({}, {"nonce": 5}, {"nonce": "x"}, {"nonce": NONCE.upper()}):
            vpn.write_request(self.uid, doc)
            with self.subTest(doc=str(doc)), self.assertRaises(vpn.VpnError):
                self.apply("off")
        self.assertEqual(self.stubs.calls(), [])
        self.assertIsNone(self.served())

    def test_an_operation_that_is_not_in_the_closed_set_does_nothing(self):
        for instance in ("", "../", "connect-;rm", "arm-1000", "connect"):
            with self.subTest(instance=instance), self.assertRaises(vpn.VpnError):
                helper.apply(instance)
        self.assertEqual(self.stubs.calls(), [])

    def test_importing_names_marks_and_routes_the_dns_of_the_connection(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("NL-792.conf", PROTON_CONF))
        self.apply("import")
        (imported,) = self.stubs.called("nmcli", "connection", "import")
        self.assertEqual(imported["argv"], ["connection", "import", "type", "wireguard", "file",
                                            str(self.tmp / "run" / "vekrona-vpn" / "import" / vpn.CONF_FILE_NAME)])
        self.assertEqual(imported["file"], vpn.render_import_conf(vpn.parse_conf(PROTON_CONF)))
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        argv = modified["argv"]
        self.assertEqual(argv[:4], ["connection", "modify", "uuid", UUID_NEW])
        settings = dict(zip(argv[4::2], argv[5::2]))
        self.assertEqual(settings["connection.id"], "vekrona-vpn/other/NL/NL-792")
        self.assertEqual(settings["connection.interface-name"], vpn.INTERFACE)
        self.assertEqual(settings["connection.autoconnect"], "no")
        self.assertEqual(settings["wireguard.peer-routes"], "yes")
        self.assertEqual(settings["wireguard.private-key"], "")
        self.assertEqual(settings["wireguard.private-key-flags"], "2")
        self.assertEqual(int(settings["wireguard.fwmark"], 16), vpn.WG_FWMARK)
        self.assertEqual(settings["ipv4.dns-search"], "~.")
        self.assertEqual(list((self.tmp / "run" / "vekrona-vpn" / "import").iterdir()), [])
        self.assertEqual(self.stubs.called("nmcli", "connection", "delete"), [])

    def test_the_profile_is_born_without_routes_and_gets_them_in_the_change_that_turns_autoconnect_off(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("NL-792.conf", PROTON_CONF))
        self.apply("import")
        (imported,) = self.stubs.called("nmcli", "connection", "import")
        self.assertIn("\nTable = off\n", imported["file"])
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        self.assertIn("connection.autoconnect", modified["argv"])
        self.assertIn("wireguard.peer-routes", modified["argv"])

    def test_a_profile_is_born_on_an_interface_of_its_own_so_that_it_cannot_replace_the_tunnel_in_use(self):
        self.assertNotEqual(vpn.IMPORT_NAME, vpn.INTERFACE)
        self.assertLessEqual(len(vpn.IMPORT_NAME), 15)
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")], active=[(UUID_A, "activated")])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("DE-1.conf", PROTON_CONF))
        self.apply("import")
        (imported,) = self.stubs.called("nmcli", "connection", "import")
        self.assertEqual(Path(imported["argv"][-1]).name, vpn.IMPORT_NAME + ".conf")
        self.assertEqual(self.nmcli_actions(), [imported["argv"], self.stubs.called("nmcli", "connection", "modify")[0]["argv"]])

    def test_a_profile_left_unfinished_by_a_killed_import_is_deleted_before_the_next_import(self):
        self.stubs.behave("nmcli", ["-t", "-f", "UUID,TYPE,NAME", "connection", "show"],
                          stdout="%s:wireguard:%s\n%s:wireguard:%s\n" % (UUID_OLD, vpn.IMPORT_NAME, UUID_A, terse("vekrona-vpn/other/NL/NL-1")))
        self.nm_imports_as(UUID_NEW)
        self.import_request(("NL-792.conf", PROTON_CONF))
        self.apply("import")
        self.assertEqual([action[:2] for action in self.nmcli_actions()], [["connection", "delete"], ["connection", "import"], ["connection", "modify"]])
        self.assertEqual(self.nmcli_actions()[0], ["connection", "delete", "uuid", UUID_OLD])

    def test_a_batch_that_fails_halfway_says_how_many_files_were_imported(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_B)  # every import after the first
        self.stubs.behave("nmcli", ["connection", "import"], times=1,
                          stdout="Connection '%s' (%s) successfully added.\n" % (vpn.IMPORT_NAME, UUID_NEW))
        self.stubs.behave("nmcli", ["connection", "modify", "uuid", UUID_B], rc=2, stderr="Error: invalid property\n")
        self.import_request(("NL-1.conf", PROTON_CONF), ("NL-2.conf", PROTON_CONF), ("NL-3.conf", PROTON_CONF))
        with self.assertRaisesRegex(vpn.VpnError, r"file 2: nmcli connection modify failed.*\(1 of 3 files were imported before it\)"):
            self.apply("import")
        self.assertEqual(len(self.stubs.called("nmcli", "connection", "import")), 2)
        self.assertEqual(len(self.stubs.called("nmcli", "connection", "delete", "uuid", UUID_NEW)), 1)

    def test_a_connection_that_a_failed_import_made_that_cannot_be_deleted_is_named_in_the_error(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_B)
        self.stubs.behave("nmcli", ["connection", "import"], times=1,
                          stdout="Connection '%s' (%s) successfully added.\n" % (vpn.IMPORT_NAME, UUID_NEW))
        self.stubs.behave("nmcli", ["connection", "modify", "uuid", UUID_B], rc=2, stderr="Error: invalid property\n")
        self.stubs.behave("nmcli", ["connection", "delete", "uuid", UUID_NEW], rc=3, stderr="Error: busy\n")
        self.import_request(("NL-1.conf", PROTON_CONF), ("NL-2.conf", PROTON_CONF))
        with self.assertRaisesRegex(vpn.VpnError, r"file 2: .*\(1 of 2 files were imported before it\); and these connections could not "
                                                  r"be removed: %s" % UUID_NEW):
            self.apply("import")

    def test_an_import_with_a_preshared_key_writes_the_whole_peer_with_flag_4_and_never_the_key(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("NL-792.conf", PROTON_CONF.replace("[Peer]\n", "[Peer]\nPresharedKey = %s\n" % KEY_PSK)))
        self.apply("import")
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        settings = dict(zip(modified["argv"][4::2], modified["argv"][5::2]))
        self.assertEqual(settings["wireguard.peers"],
                         "%s endpoint=203.0.113.9:51820 allowed-ips=0.0.0.0/0;::/0 preshared-key-flags=4" % KEY_PEER)
        self.assertNotIn(KEY_PSK, json.dumps(self.stubs.argvs()))

    def test_a_profile_that_networkmanager_autoconnected_before_it_was_changed_is_taken_down(self):
        self.nm_lists([(UUID_NEW, "vekrona-vpn/other/??/just-imported")], active=[(UUID_NEW, "activated")])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("NL-792.conf", PROTON_CONF))
        self.apply("import")
        self.assertEqual([action[1] for action in self.nmcli_actions()], ["import", "modify", "down"])
        self.assertEqual(self.nmcli_actions()[-1], ["connection", "down", "uuid", UUID_NEW])

    def test_the_file_name_gives_the_country_and_a_name_with_no_country_is_unknown(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("Zürich-and-a-very-long-name-that-goes-on-and-on.conf", PROTON_CONF), vendor="other")
        self.apply("import")
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        self.assertEqual(modified["argv"][5], "vekrona-vpn/other/??/Zürich-and-a-very-long-name-that-goes-on-and-on")

    def test_one_bad_file_imports_none(self):
        self.import_request(("NL-1.conf", PROTON_CONF), ("garbage.conf", "lizard " + SECRET_WORD))
        with self.assertRaises(vpn.VpnError) as raised:
            self.apply("import")
        self.assertIn("file 2", str(raised.exception))
        self.assertNotIn(SECRET_WORD, str(raised.exception))
        self.assertEqual(self.stubs.called("nmcli"), [])

    def test_a_lone_surrogate_in_a_configuration_is_one_line_error_not_a_crash(self):
        self.import_request(("a.conf", "\ud800"))
        with self.assertRaisesRegex(vpn.VpnError, "file 1: the text is not valid Unicode"):
            self.apply("import")
        self.assertEqual(self.stubs.called("nmcli"), [])

    def test_a_request_that_is_not_an_import_is_refused(self):
        for doc in ({"vendor": "mullvad", "files": []}, {"vendor": "proton", "files": []},
                    {"vendor": "proton", "files": [{"file": "a.conf"}]}, {"vendor": "proton", "files": "x"},
                    {"vendor": "proton", "files": [{"file": "a.conf", "text": PROTON_CONF}] * (vpn.MAX_FILES + 1)}, {}):
            self.request(doc)
            with self.subTest(doc=str(doc)[:40]), self.assertRaises(vpn.VpnError):
                self.apply("import")
        self.assertEqual(self.stubs.called("nmcli"), [])

    def test_importing_again_replaces_the_connection_of_the_same_id_after_the_new_one_exists(self):
        self.nm_lists([(UUID_OLD, "vekrona-vpn/other/NL/NL-792")])
        self.nm_imports_as(UUID_NEW)
        self.import_request(("NL-792.conf", PROTON_CONF))
        self.apply("import")
        order = [call["argv"][1] for call in self.stubs.called("nmcli", "connection")]
        self.assertEqual(order, ["import", "modify", "delete"])
        self.assertEqual(self.stubs.called("nmcli", "connection", "delete")[0]["argv"], ["connection", "delete", "uuid", UUID_OLD])

    def test_a_connection_that_cannot_be_set_up_is_removed_again(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_NEW)
        self.stubs.behave("nmcli", ["connection", "modify"], rc=2, stderr="Error: invalid property\n")
        self.import_request(("NL-1.conf", PROTON_CONF))
        with self.assertRaises(vpn.VpnError):
            self.apply("import")
        self.assertEqual(self.stubs.called("nmcli", "connection", "delete")[0]["argv"], ["connection", "delete", "uuid", UUID_NEW])

    def test_a_connection_that_cannot_be_set_up_or_removed_says_both(self):
        self.nm_lists([])
        self.nm_imports_as(UUID_NEW)
        self.stubs.behave("nmcli", ["connection", "modify"], rc=2)
        self.stubs.behave("nmcli", ["connection", "delete"], rc=3)
        self.import_request(("NL-1.conf", PROTON_CONF))
        with self.assertRaisesRegex(vpn.VpnError, UUID_NEW):
            self.apply("import")

    def test_connecting_arms_for_the_endpoint_first_then_takes_the_other_tunnel_down_and_brings_this_one_up_with_its_keys(self):
        self.nm_lists([(UUID_A, CONFIG_ID), (UUID_B, "vekrona-vpn/other/??/home")], active=[(UUID_B, "activated")])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.request({"uuid": UUID_A, "keys": KEYS})
        self.apply("connect")
        calls = self.stubs.argvs()
        arm = calls.index(["nft", "-f", "-"])
        down = calls.index(["nmcli", "connection", "down", "uuid", UUID_B])
        recheck = calls.index(["nft", "list", "table", "inet", "vekrona-vpn"])
        up = index_starting(calls, ["nmcli", "--wait", str(vpn.NM_UP_WAIT_SEC), "connection", "up", "uuid", UUID_A])
        self.assertLess(arm, down)
        self.assertLess(down, recheck)
        self.assertLess(recheck, up)
        self.assertIn("elements = { 203.0.113.9 . 51820 }", self.stubs.called("nft", "-f")[0]["stdin"])
        self.assertEqual(self.stubs.called("nmcli", "--wait")[0]["stdin"], "wireguard.private-key:%s\n" % KEY_PRIVATE)
        self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": UUID_A})
        self.assertEqual(len([c for c in calls if c[:3] == ["nmcli", "connection", "down"]]), 1)

    def test_connecting_refuses_keys_that_are_not_wireguard_keys_before_arming(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.request({"uuid": UUID_A, "keys": {"private_key": "lizard"}})
        with self.assertRaisesRegex(vpn.VpnError, "private_key is not a WireGuard key"):
            self.apply("connect")
        self.assertEqual(self.stubs.called("nft"), [])

    def test_connecting_with_a_preshared_key_sets_it_on_the_tunnel_after_the_activation(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.request({"uuid": UUID_A, "keys": {"private_key": KEY_PRIVATE, "preshared_key": KEY_PSK}})
        self.apply("connect")
        calls = self.stubs.argvs()
        up = index_starting(calls, ["nmcli", "--wait", str(vpn.NM_UP_WAIT_SEC), "connection", "up", "uuid", UUID_A])
        wg = index_starting(calls, ["wg", "set", vpn.INTERFACE, "peer", KEY_PEER, "preshared-key", "/dev/stdin"])
        self.assertLess(up, wg)
        self.assertEqual(self.stubs.called("wg", "set")[0]["stdin"], KEY_PSK + "\n")
        self.assertEqual(self.stubs.called("nmcli", "--wait")[0]["stdin"], "wireguard.private-key:%s\n" % KEY_PRIVATE)
        self.assertNotIn(KEY_PSK, json.dumps(self.stubs.argvs()))
        self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": UUID_A})

    def test_connecting_to_a_profile_bound_to_another_interface_is_refused_before_anything_is_armed(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820", interface="wp2c-probe")
        self.request({"uuid": UUID_A, "keys": KEYS})
        with self.assertRaisesRegex(vpn.VpnError, "%s is bound to wp2c-probe, not vvpn0" % CONFIG_ID):
            self.apply("connect")
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertEqual(self.stubs.called("nmcli", "--wait"), [])
        self.assertFalse(self.state_file().exists())

    def test_a_preshared_key_that_wg_refuses_takes_the_tunnel_down_and_keeps_the_kill_switch_armed(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.stubs.behave("wg", ["set"], rc=2, stderr="Error: invalid key\n")
        self.request({"uuid": UUID_A, "keys": {"private_key": KEY_PRIVATE, "preshared_key": KEY_PSK}})
        with self.assertRaisesRegex(vpn.VpnError, "kill switch stays armed") as raised:
            self.apply("connect")
        self.assertNotIn(KEY_PSK, str(raised.exception))
        self.assertIn(["nmcli", "connection", "down", "uuid", UUID_A], self.stubs.argvs())
        self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": UUID_A})

    def test_connecting_to_what_is_not_a_connection_of_vekrona_vpn_does_nothing(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")])
        for doc in ({"uuid": UUID_B}, {"uuid": "../"}, {"uuid": ""}, {"uuid": 5}, {"uuid": UUID_A.upper()}, {}, {"mullvad": "x"}):
            self.request(doc)
            with self.subTest(doc=str(doc)), self.assertRaises(vpn.VpnError):
                self.apply("connect")
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertEqual(self.nmcli_actions(), [])

    def test_a_failure_after_arming_leaves_the_kill_switch_armed(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.stubs.behave("nmcli", ["--wait", str(vpn.NM_UP_WAIT_SEC), "connection", "up"], rc=4, stderr="Error: Connection activation failed\n")
        self.request({"uuid": UUID_A, "keys": KEYS})
        with self.assertRaises(vpn.VpnError):
            self.apply("connect")
        (load,) = self.stubs.called("nft", "-f")
        self.assertIn("table inet vekrona-vpn {", load["stdin"])
        self.assertEqual(self.state(), {"schema": 1, "armed": True, "uuid": UUID_A})

    def test_a_kill_switch_that_is_gone_before_the_tunnel_comes_up_keeps_the_tunnel_down(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820")
        self.stubs.behave("nft", ["list", "table"], rc=1, stderr="Error: No such file or directory\n")
        self.request({"uuid": UUID_A, "keys": KEYS})
        with self.assertRaisesRegex(vpn.VpnError, "kill switch is not loaded"):
            self.apply("connect")
        self.assertEqual(self.stubs.called("nmcli", "--wait"), [])

    def test_every_operation_runs_under_the_lock_that_arming_and_removing_the_kill_switch_need(self):
        held = []

        def probe(request):
            with open(self.tmp / "run" / "vekrona-vpn" / vpn.LOCK_NAME, "a") as other:
                try:
                    fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    held.append(True)
                else:
                    held.append(False)

        with mock.patch.dict(helper.OPERATIONS, {op: probe for op in vpn.OPS if op != "seal"}):
            for op in (op for op in vpn.OPS if op != "seal"):
                self.request({})
                self.apply(op)
        self.assertEqual(held, [True] * (len(vpn.OPS) - 1))

    def test_connecting_to_mullvad_builds_the_connection_from_the_device_of_the_request_and_replaces_the_countrys_old_one(self):
        self.nm_lists([(UUID_B, "vekrona-vpn/mullvad/SE/se-got-wg-001"), (UUID_OLD, "vekrona-vpn/mullvad/NL/nl-ams-wg-009")])
        self.nm_imports_as(UUID_NEW)
        self.nm_peer_of(UUID_NEW, "198.51.100.7:51820")
        self.request({"vendor": "mullvad", "relay": relay_dict(), "device": DEVICE_DOC})
        self.apply("connect")
        (imported,) = self.stubs.called("nmcli", "connection", "import")
        conf = vpn.parse_conf(imported["file"].replace("Table = off\n", "").replace(vpn.PLACEHOLDER_KEY, KEY_PRIVATE))
        self.assertEqual((conf.private_key, conf.peer_public_key, conf.endpoint), (KEY_PRIVATE, KEY_RELAY, vpn.Endpoint("198.51.100.7", 51820)))
        self.assertEqual(conf.addresses, ("10.66.0.5/32", "fc00:bbbb:bbbb:bb01::5/128"))
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        self.assertEqual(modified["argv"][5], "vekrona-vpn/mullvad/NL/nl-ams-wg-001")
        self.assertEqual(self.stubs.called("nmcli", "--wait")[0]["stdin"], "wireguard.private-key:%s\n" % KEY_PRIVATE)
        calls = self.stubs.argvs()
        up = index_starting(calls, ["nmcli", "--wait", str(vpn.NM_UP_WAIT_SEC), "connection", "up", "uuid", UUID_NEW])
        old = calls.index(["nmcli", "connection", "delete", "uuid", UUID_OLD])
        self.assertLess(up, old)
        self.assertNotIn(["nmcli", "connection", "delete", "uuid", UUID_B], calls)



    def test_a_relay_with_a_newline_in_a_field_is_refused(self):
        self.nm_lists([(UUID_B, "vekrona-vpn/mullvad/SE/se-got-wg-001")])
        for bad in (relay_dict(hostname="nl\nPostUp = x"), relay_dict(public_key="short"), relay_dict(ipv4="vpn.example.com"),
                    relay_dict(country="nl\n"), {**relay_dict(), "extra": 1}):
            self.request({"vendor": "mullvad", "relay": bad, "device": DEVICE_DOC})
            with self.subTest(bad=str(bad)[:30]), self.assertRaises(vpn.VpnError):
                self.apply("connect")
        self.assertEqual(self.nmcli_actions(), [])

    def test_logging_in_replaces_every_connection_of_the_old_account(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/mullvad/SE/se-got-wg-001"), (UUID_B, "vekrona-vpn/mullvad/NL/nl-ams-wg-009"),
                       (UUID_OLD, "vekrona-vpn/other/NL/NL-792")])
        self.nm_imports_as(UUID_NEW)
        self.request({"device": {"private_key": KEY_PRIVATE, "ipv4_address": "10.66.0.5/32", "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"},
                      "relay": relay_dict()})
        self.apply("login")
        deleted = [call["argv"][3] for call in self.stubs.called("nmcli", "connection", "delete")]
        self.assertEqual(sorted(deleted), sorted([UUID_A, UUID_B]))
        self.assertEqual(self.stubs.called("nmcli", "--wait"), [])
        self.assertEqual(self.stubs.called("nft"), [])

    def test_a_device_with_a_bad_key_or_address_is_refused(self):
        self.nm_lists([])
        for device in ({"private_key": "x", "ipv4_address": "10.66.0.5/32", "ipv6_address": "fc00::5/128"},
                       {"private_key": KEY_PRIVATE, "ipv4_address": "vpn.example.com", "ipv6_address": "fc00::5/128"},
                       {"private_key": KEY_PRIVATE, "ipv4_address": "10.66.0.5/32"}, "device", None,
                       {"private_key": KEY_PRIVATE, "ipv4_address": "10.66.0.5/32", "ipv6_address": "fe80::5%eth0/128"},
                       {"private_key": KEY_PRIVATE, "ipv4_address": "10.66.0.5/32", "ipv6_address": "fc00::5%x\nPostUp = y/128"},
                       {"private_key": KEY_PRIVATE, "ipv4_address": 5, "ipv6_address": "fc00::5/128"}):
            self.request({"device": device, "relay": relay_dict()})
            with self.subTest(device=str(device)[:30]), self.assertRaises(vpn.VpnError):
                self.apply("login")
        self.assertEqual(self.stubs.called("nmcli", "connection"), [])

    def test_turning_off_takes_down_what_is_active_and_nothing_else_and_then_removes_the_kill_switch(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792"), (UUID_B, "vekrona-vpn/other/??/home")], active=[(UUID_A, "activating")])
        self.request({})
        self.apply("off")
        self.assertEqual(self.nmcli_actions(), [["connection", "down", "uuid", UUID_A]])
        calls = self.stubs.argvs()
        self.assertLess(calls.index(["nmcli", "connection", "down", "uuid", UUID_A]), calls.index(["nft", "-f", "-"]))
        self.assertEqual(self.stubs.called("nft", "-f")[0]["stdin"], vpn.render_disarm())
        self.assertEqual(self.state(), {"schema": 1, "armed": False, "uuid": None})

    def test_turning_off_with_nothing_active_still_removes_the_kill_switch(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")])
        self.request({})
        self.apply("off")
        self.assertEqual(self.nmcli_actions(), [])
        self.assertEqual(len(self.stubs.called("nft", "-f")), 1)

    def test_a_tunnel_that_cannot_be_taken_down_leaves_the_kill_switch_where_it_is(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")], active=[(UUID_A, "activated")])
        self.stubs.behave("nmcli", ["connection", "down"], rc=1, stderr="Error: timeout\n")
        self.request({})
        with self.assertRaises(vpn.VpnError):
            self.apply("off")
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertFalse((self.tmp / "run" / "vekrona-vpn" / "state.json").exists())

    def test_forgetting_removes_the_connection_and_takes_it_down_first_when_active(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")], active=[(UUID_A, "activated")])
        self.request({"uuid": UUID_A})
        self.apply("forget")
        self.assertEqual(self.nmcli_actions(), [["connection", "down", "uuid", UUID_A], ["connection", "delete", "uuid", UUID_A]])

    def test_forgetting_what_is_not_ours_removes_nothing(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")])
        for doc in ({"uuid": UUID_B}, {"uuid": "../"}, {"uuid": ""}, {"uuid": None}, {}):
            self.request(doc)
            with self.subTest(doc=str(doc)), self.assertRaises(vpn.VpnError):
                self.apply("forget")
        self.assertEqual(self.nmcli_actions(), [])

    def test_seal_export_hands_over_the_keys_of_the_connections_whose_keyfile_holds_them_and_nothing_else(self):
        self.nm_lists([(UUID_A, CONFIG_ID), (UUID_B, "vekrona-vpn/other/??/sealed")])
        self.nm_read(UUID_A, SEAL_FIELDS, ["0 (none)", KEY_PRIVATE, "%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820 preshared-key=%s"
                                           % (KEY_PEER, KEY_PSK), "10.2.0.2/32", ""], with_secrets=True)
        self.nm_read(UUID_B, SEAL_FIELDS, ["2 (not-saved)", "", "", "", ""], with_secrets=True)
        self.request({"phase": "export"})
        self.apply("seal")
        path = Path(vpn.sealed_path(self.uid))
        self.assertEqual(json.loads(path.read_text()), [{"uuid": UUID_A, "id": CONFIG_ID, "vendor": "other", "private_key": KEY_PRIVATE,
                                                         "preshared_key": KEY_PSK, "ipv4_address": "10.2.0.2/32", "ipv6_address": ""}])
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(path.stat().st_uid, self.uid)
        self.assertEqual(path.stat().st_gid, pwd.getpwuid(self.uid).pw_gid)

    def test_seal_export_with_every_key_sealed_already_hands_over_an_empty_list(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_read(UUID_A, SEAL_FIELDS, ["2 (not-saved)", "", "", "", ""], with_secrets=True)
        self.request({"phase": "export"})
        self.apply("seal")
        self.assertEqual(json.loads(Path(vpn.sealed_path(self.uid)).read_text()), [])

    def test_seal_strip_clears_the_keys_of_the_connections_and_checks_that_no_keyfile_holds_one(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_read(UUID_A, ["wireguard.peers"], ["%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820 preshared-key=%s"
                                                   % (KEY_PEER, KEY_PSK)], with_secrets=True)
        self.keyfile(UUID_A)
        self.request({"phase": "strip", "uuids": [UUID_A]})
        self.apply("seal")
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        settings = dict(zip(modified["argv"][4::2], modified["argv"][5::2]))
        self.assertEqual(settings["wireguard.private-key"], "")
        self.assertEqual(settings["wireguard.private-key-flags"], "2")
        self.assertEqual(settings["wireguard.peers"], "%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820 preshared-key-flags=4" % KEY_PEER)
        self.assertNotIn(KEY_PSK, json.dumps(modified["argv"]))

    def test_seal_strip_moves_a_profile_onto_the_tunnel_interface_the_kill_switch_accepts(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_read(UUID_A, ["wireguard.peers"], ["%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER], with_secrets=True)
        self.keyfile(UUID_A)
        self.request({"phase": "strip", "uuids": [UUID_A]})
        self.apply("seal")
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        settings = dict(zip(modified["argv"][4::2], modified["argv"][5::2]))
        self.assertEqual(settings["connection.interface-name"], vpn.INTERFACE)

    def test_seal_strip_fails_while_a_keyfile_still_holds_a_key_and_never_says_which(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_read(UUID_A, ["wireguard.peers"], ["%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER], with_secrets=True)
        self.keyfile(UUID_A, "[wireguard]\nprivate-key=%s\n" % KEY_PRIVATE)
        self.request({"phase": "strip", "uuids": [UUID_A]})
        with self.assertRaisesRegex(vpn.VpnError, "still holds a key") as raised:
            self.apply("seal")
        self.assertNotIn(KEY_PRIVATE, str(raised.exception))

    def test_seal_strip_refuses_a_connection_that_is_not_ours_and_a_phase_that_is_not_known(self):
        self.nm_lists([])
        self.request({"phase": "strip", "uuids": [UUID_A]})
        with self.assertRaisesRegex(vpn.VpnError, "not a connection of vekrona-vpn"):
            self.apply("seal")
        self.request({"phase": "burn"})
        with self.assertRaisesRegex(vpn.VpnError, "no phase of that name"):
            self.apply("seal")
        self.assertEqual(self.nmcli_actions(), [])

    def test_a_stale_export_is_removed_by_the_next_operation_of_its_user(self):
        vpn.write_sealed(self.uid, [{"uuid": UUID_A}])
        self.assertTrue(Path(vpn.sealed_path(self.uid)).exists())
        self.nm_lists([])
        self.request({})
        self.apply("off")
        self.assertFalse(Path(vpn.sealed_path(self.uid)).exists())

    def test_the_helper_refuses_a_batch_whose_files_make_the_same_connection(self):
        self.nm_lists([])
        self.import_request(("NL-792.conf", PROTON_CONF), ("NL-792.CONF", PROTON_CONF))
        with self.assertRaisesRegex(vpn.VpnError, "would both make the connection"):
            self.apply("import")
        self.assertEqual(self.stubs.called("nmcli"), [])


    def test_main_refuses_to_run_without_root(self):
        stderr = io.StringIO()
        with mock.patch.object(os, "geteuid", return_value=1000), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(["vekrona-vpn-apply", "apply", "off-%d" % self.uid]), 1)
        self.assertIn("needs root", stderr.getvalue())
        self.assertEqual(self.stubs.calls(), [])

    def test_main_refuses_unknown_commands(self):
        for argv in (["bogus"], ["arm"], ["disarm"], ["apply"], ["apply", "off-1", "extra"]):
            stderr = io.StringIO()
            with self.subTest(argv=argv), mock.patch.object(os, "geteuid", return_value=0), contextlib.redirect_stderr(stderr):
                self.assertEqual(helper.main(["vekrona-vpn-apply", *argv]), helper.EXIT_USAGE)
            self.assertIn("usage", stderr.getvalue())
        self.assertEqual(self.stubs.calls(), [])


    def test_connecting_to_proton_replaces_every_generated_proton_connection_and_never_an_import_of_before_wp3(self):
        # A generated connection of another country is replaced; an import of `proton` made before WP3 (any other last segment) is not.
        self.nm_lists([(UUID_OLD, "vekrona-vpn/proton/DE/signed-in"), (UUID_B, "vekrona-vpn/proton/NL/NL-792")])
        self.nm_imports_as(UUID_NEW)
        self.nm_peer_of(UUID_NEW, "203.0.113.9:51820")
        self.request({"vendor": "proton", "id": "vekrona-vpn/proton/NL/signed-in", "conf": PROTON_CONF, "private_key": KEY_PRIVATE})
        self.apply("connect")
        (imported,) = self.stubs.called("nmcli", "connection", "import")
        self.assertIn(vpn.PLACEHOLDER_KEY, imported["file"])
        self.assertNotIn(KEY_PRIVATE, imported["file"])
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        self.assertEqual(modified["argv"][5], "vekrona-vpn/proton/NL/signed-in")
        self.assertEqual(self.stubs.called("nmcli", "--wait")[0]["stdin"], "wireguard.private-key:%s\n" % KEY_PRIVATE)
        calls = self.stubs.argvs()
        up = index_starting(calls, ["nmcli", "--wait", str(vpn.NM_UP_WAIT_SEC), "connection", "up", "uuid", UUID_NEW])
        self.assertLess(up, calls.index(["nmcli", "connection", "delete", "uuid", UUID_OLD]))
        self.assertNotIn(["nmcli", "connection", "delete", "uuid", UUID_B], calls)

    def test_a_proton_request_with_a_foreign_id_a_key_of_another_configuration_or_no_configuration_is_refused_before_arming(self):
        good = {"vendor": "proton", "id": "vekrona-vpn/proton/NL/signed-in", "conf": PROTON_CONF, "private_key": KEY_PRIVATE}
        for changed in ({"id": "vekrona-vpn/other/NL/signed-in"}, {"id": "vekrona-vpn/proton/??/signed-in"}, {"id": "vekrona-vpn/proton/NL/NL#6"},
                        {"id": "vekrona-vpn/proton/NL/signed-in "}, {"private_key": KEY_PSK}, {"conf": None}, {"conf": conf_without("PrivateKey")}):
            with self.subTest(changed=str(changed)), self.assertRaises(vpn.VpnError):
                self.request({**good, **changed})
                self.apply("connect")
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertEqual(self.nmcli_actions(), [])


    def test_a_proton_request_whose_configuration_holds_a_preshared_key_is_refused_before_arming(self):
        self.request({"vendor": "proton", "id": "vekrona-vpn/proton/NL/signed-in", "private_key": KEY_PRIVATE,
                      "conf": PROTON_CONF.replace("AllowedIPs", "PresharedKey = %s\nAllowedIPs" % KEY_PSK)})
        with self.assertRaisesRegex(vpn.VpnError, "preshared key"):
            self.apply("connect")
        self.assertEqual((self.stubs.called("nft"), self.nmcli_actions()), ([], []))


def relay_list_doc(extra_relays=()):
    relays = [
        {"hostname": "nl-ams-wg-001", "location": "nl-ams", "active": True, "public_key": KEY_RELAY, "ipv4_addr_in": "198.51.100.7"},
        {"hostname": "nl-ams-wg-002", "location": "nl-ams", "active": False, "public_key": KEY_RELAY, "ipv4_addr_in": "198.51.100.8"},
        {"hostname": "se-got-wg-001", "location": "se-got", "active": True, "public_key": KEY_PEER, "ipv4_addr_in": "198.51.100.9"},
        *extra_relays,
    ]
    return {"locations": {"nl-ams": {"country": "Netherlands"}, "se-got": {"country": "Sweden"}, "de-fra": {"country": "Germany"}},
            "wireguard": {"relays": relays}}


class MullvadSandbox(Sandbox):
    """The sandbox with Mullvad's API behind a local server and `wg` making fixed keys."""

    def setUp(self):
        super().setUp()
        self.api = ApiFixture()
        self.api.start()
        self.addCleanup(self.api.stop)
        patched = mock.patch.object(mullvad, "MULLVAD_API", self.api.base)
        patched.start()
        self.addCleanup(patched.stop)
        self.api.answer("GET", "/app/v1/relays", relay_list_doc())
        self.api.answer("GET", "/accounts/v1/devices", [])
        self.stubs.behave("wg", ["genkey"], stdout=KEY_PRIVATE + "\n")
        self.stubs.behave("wg", ["pubkey"], stdout=KEY_PUBLIC + "\n")


class MullvadTest(MullvadSandbox):
    def stderr_of(self, function, *args):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            result = function(*args)
        return result, stderr.getvalue()

    def test_the_relay_list_keeps_active_relays_by_country_and_is_cached(self):
        relays = mullvad.load_relays(str(self.relay_cache))
        self.assertEqual(relays["names"], {"nl": "Netherlands", "se": "Sweden"})
        self.assertEqual(sorted(r["hostname"] for r in relays["relays"]), ["nl-ams-wg-001", "se-got-wg-001"])
        self.assertEqual(json.loads(self.relay_cache.read_text()), relays)
        self.assertEqual(stat.S_IMODE(self.relay_cache.stat().st_mode), 0o600)

    def test_a_relay_whose_fields_could_inject_a_line_is_left_out_and_said(self):
        evil = {"hostname": "nl-evil\nPostUp = x", "location": "nl-ams", "active": True, "public_key": KEY_RELAY, "ipv4_addr_in": "198.51.100.1"}
        self.api.answer("GET", "/app/v1/relays", relay_list_doc([evil]))
        relays, stderr = self.stderr_of(mullvad.load_relays, str(self.relay_cache))
        self.assertEqual(len(relays["relays"]), 2)
        self.assertIn("ignoring a relay", stderr)

    def test_an_unreachable_api_falls_back_to_the_cache_and_says_so(self):
        mullvad.load_relays(str(self.relay_cache))
        with mock.patch.object(mullvad, "MULLVAD_API", unused_port_base()):
            relays, stderr = self.stderr_of(mullvad.load_relays, str(self.relay_cache))
        self.assertEqual(sorted(relays["names"]), ["nl", "se"])
        self.assertIn("using the cache", stderr)

    def test_an_unreachable_api_and_no_cache_is_an_error(self):
        with mock.patch.object(mullvad, "MULLVAD_API", unused_port_base()), self.assertRaisesRegex(vpn.VpnError, "no cache"):
            mullvad.load_relays(str(self.relay_cache))

    def test_an_answer_of_another_shape_is_treated_as_unreachable(self):
        self.api.answer("GET", "/app/v1/relays", {"unexpected": 1})
        with self.assertRaisesRegex(vpn.VpnError, "no cache"):
            mullvad.load_relays(str(self.relay_cache))

    def test_a_damaged_cache_is_an_error_not_an_empty_list(self):
        self.relay_cache.parent.mkdir(parents=True)
        self.relay_cache.write_text("{not json")
        self.api.answer("GET", "/app/v1/relays", {"unexpected": 1})
        with self.assertRaisesRegex(vpn.VpnError, "unusable"):
            mullvad.load_relays(str(self.relay_cache))

    def test_a_relay_list_that_cannot_be_cached_is_an_error_not_a_traceback(self):
        (self.tmp / "cache").write_text("a file where the cache directory belongs")
        with self.assertRaisesRegex(vpn.VpnError, "cannot write"):
            mullvad.load_relays(str(self.relay_cache))

    def test_a_cached_relay_list_whose_country_names_are_not_codes_with_a_text_each_is_not_used(self):
        self.relay_cache.parent.mkdir(parents=True)
        for names in ({"nl": 5}, {"NL": "Netherlands"}, {"netherlands": "Netherlands"}, {"n": "x"}, []):
            self.relay_cache.write_text(json.dumps({"names": names, "relays": []}))
            with self.subTest(names=names), self.assertRaisesRegex(vpn.VpnError, "unusable"):
                mullvad.read_cache(str(self.relay_cache))

    def test_an_api_answer_with_a_country_name_that_is_not_text_is_treated_as_unreachable(self):
        self.api.answer("GET", "/app/v1/relays", {**relay_list_doc(), "locations": {"nl-ams": {"country": 5}, "se-got": {"country": "Sweden"}}})
        with self.assertRaisesRegex(vpn.VpnError, "no cache"):
            mullvad.load_relays(str(self.relay_cache))

    def test_a_relay_of_the_country_is_chosen_and_an_unknown_country_or_empty_list_is_an_error(self):
        relays = mullvad.load_relays(str(self.relay_cache))
        self.assertEqual(mullvad.select_relay(relays, "nl").hostname, "nl-ams-wg-001")
        with self.assertRaisesRegex(vpn.VpnError, "no active relay in DE"):
            mullvad.select_relay(relays, "de")
        with self.assertRaisesRegex(vpn.VpnError, "empty"):
            mullvad.any_relay({"names": {}, "relays": []})

    def test_the_account_number_is_digits_from_stdin(self):
        self.assertEqual(mullvad.read_account(io.StringIO("1234 5678 9012 3456\n")), "1234567890123456")
        for bad in ("", "\n", "abcd\n", "1234-5678\n", "12\x00\n"):
            with self.subTest(bad=bad), self.assertRaises(vpn.VpnError):
                mullvad.read_account(io.StringIO(bad))

    def test_a_new_device_gets_prefixes_when_the_api_leaves_them_out(self):
        self.api.answer("POST", "/accounts/v1/devices", {"id": "d1", "name": "brave koala", "ipv4_address": "10.66.0.5",
                                                         "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"}, status=201)
        registered = mullvad.register_device("TOKEN", KEY_PRIVATE, KEY_PUBLIC)
        self.assertEqual((registered.id, registered.device.ipv4_address, registered.device.ipv6_address),
                         ("d1", "10.66.0.5/32", "fc00:bbbb:bbbb:bb01::5/128"))
        (request,) = self.api.requests_to("POST", "/accounts/v1/devices")
        self.assertEqual((request["authorization"], request["body"]), ("Bearer TOKEN", {"pubkey": KEY_PUBLIC, "hijack_dns": False}))

    def test_an_account_with_all_its_devices_is_told_which_and_nothing_is_removed(self):
        self.api.answer("POST", "/accounts/v1/devices", {"code": "MAX_DEVICES_REACHED"}, status=400)
        self.api.answer("GET", "/accounts/v1/devices", [{"name": "old laptop"}, {"name": "phone"}])
        with self.assertRaisesRegex(vpn.VpnError, "maximum number of devices.*old laptop, phone"):
            mullvad.register_device("TOKEN", KEY_PRIVATE, KEY_PUBLIC)
        self.assertEqual(self.api.requests_to("DELETE", "/accounts/v1/devices/old laptop"), [])

    def test_a_refused_account_and_a_device_answer_without_addresses_are_errors(self):
        self.api.answer("POST", "/auth/v1/token", {"code": "INVALID_ACCOUNT"}, status=400)
        with self.assertRaisesRegex(vpn.VpnError, "refused the account"):
            mullvad.api_token("1234567890123456")
        self.api.answer("POST", "/accounts/v1/devices", {"id": "d1"}, status=201)
        with self.assertRaisesRegex(vpn.VpnError, "lacks"):
            mullvad.register_device("TOKEN", KEY_PRIVATE, KEY_PUBLIC)

    def test_the_key_pair_comes_from_wg(self):
        self.assertEqual(mullvad.new_key_pair(), (KEY_PRIVATE, KEY_PUBLIC))
        self.assertEqual(self.stubs.called("wg", "pubkey")[0]["stdin"], KEY_PRIVATE + "\n")

    def test_a_missing_wg_is_an_error(self):
        with mock.patch.dict(os.environ, {"PATH": str(self.tmp)}), self.assertRaisesRegex(vpn.VpnError, "wg"):
            mullvad.new_key_pair()


class CliSandbox(MullvadSandbox):
    """The user's commands run in process, with the helper's unit answered by the stubs (see setUp)."""

    def setUp(self):
        super().setUp()
        self.helper_leaves_a_receipt = True  # False: another job answered, as when a start merged into the job of an interrupted call
        self.helper_failure = None  # the line the helper fails with, None: it succeeds
        self.during_helper = None  # something the helper does to the system while it runs
        real_run = vpn.run

        def run_with_helper(argv, **kwargs):
            """`systemctl start` runs the helper in the real system; here it is a stub, so a started unit leaves the receipt the helper
            leaves for the request it found."""
            if argv[0] == "systemctl" and "start" in argv:
                if self.helper_leaves_a_receipt:
                    vpn.record_receipt(self.uid, vpn.Receipt(vpn.read_request(self.uid)["nonce"], self.helper_failure))
                if self.during_helper is not None:
                    self.during_helper()
            return real_run(argv, **kwargs)

        # Every connection has a key in the keyring already, so a connect or a forget has nothing to seal; the device is logged in.
        self.stubs.behave("nmcli", ["-e", "no", "-g", "wireguard.private-key-flags"], stdout="2 (not-saved)\n")
        self.stubs.behave("nmcli", ["-e", "no", "-g", "connection.interface-name"], stdout=vpn.INTERFACE + "\n")
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, DEVICE_DOC)
        patched = mock.patch.object(vpn, "run", run_with_helper)
        patched.start()
        self.addCleanup(patched.stop)

    def run_cli(self, *argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                cli.main(list(argv))
            except SystemExit as exit_:
                return exit_.code, stdout.getvalue(), stderr.getvalue()
        return 0, stdout.getvalue(), stderr.getvalue()

    def write_state(self, armed, uuid):
        directory = self.tmp / "run" / "vekrona-vpn"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "state.json").write_text(vpn.state_text(vpn.State(armed, uuid)))

    def requests_handed_over(self):
        handed = []
        original = vpn.write_request

        def record(uid, doc):
            handed.append({key: value for key, value in doc.items() if key != "nonce"})
            original(uid, doc)

        return handed, mock.patch.object(vpn, "write_request", record)

class CliTest(CliSandbox):
    def test_status_prints_one_json_object(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/mullvad/NL/nl-ams-wg-001")], active=[(UUID_A, "activated")])
        self.write_state(True, UUID_A)
        code, out, err = self.run_cli("status")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(json.loads(out), {"schema": 1, "armed": True, "tunnel": "up", "mullvad": {"logged_in": True},
                                           "proton": {"logged_in": False, "netshield": 1, "error": ""},
                                           "connection": {"uuid": UUID_A, "vendor": "mullvad", "country": "NL", "name": "nl-ams-wg-001"}})

    def test_status_before_anything_was_armed(self):
        self.nm_lists([])
        code, out, err = self.run_cli("status")
        self.assertEqual((code, json.loads(out)["armed"], json.loads(out)["connection"]), (0, False, None))

    def test_status_with_a_state_file_it_does_not_know_fails_with_one_line(self):
        self.nm_lists([])
        (self.tmp / "run" / "vekrona-vpn").mkdir(parents=True)
        for text in ("{nope", "[" * 500000, "[]", json.dumps({"schema": 2, "armed": False, "uuid": None}),
                     json.dumps({"schema": 1, "armed": "yes", "uuid": None}), json.dumps({"schema": 1, "armed": True, "uuid": "../"}),
                     json.dumps({"schema": 1, "armed": True, "uuid": 5})):
            (self.tmp / "run" / "vekrona-vpn" / "state.json").write_text(text)
            code, out, err = self.run_cli("status")
            with self.subTest(text=text[:30]):
                self.assertEqual((code, out), (1, ""))
                self.assertEqual(len(err.strip().splitlines()), 1)

    def test_list_without_an_account_asks_mullvad_for_nothing(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/other/NL/NL-792")])
        code, out, err = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertEqual(self.api.requests, [])
        self.assertEqual(json.loads(out)["vendors"][0]["countries"], [])

    def test_list_with_an_account_fetches_a_missing_relay_list_once_and_then_uses_the_cache(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/mullvad/NL/nl-ams-wg-001")])
        _, out, _ = self.run_cli("list")
        self.assertEqual([c["code"] for c in json.loads(out)["vendors"][0]["countries"]], ["NL", "SE"])
        self.run_cli("list")
        self.assertEqual(len(self.api.requests_to("GET", "/app/v1/relays")), 1)

    def test_list_with_an_account_and_no_way_to_reach_mullvad_still_lists_and_says_why(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/mullvad/NL/nl-ams-wg-001"), (UUID_B, "vekrona-vpn/other/DE/de-1")])
        with mock.patch.object(mullvad, "MULLVAD_API", unused_port_base()):
            code, out, err = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertIn("no cache", err)
        vendors = json.loads(out)["vendors"]
        self.assertEqual((vendors[0]["countries"], vendors[2]["countries"][0]["code"]), ([], "DE"))

    def test_connect_by_uuid_hands_the_uuid_and_its_keys_to_the_helper_and_takes_the_request_back(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.seed(secrets.CONFIG_KEY, CONFIG_ID, KEYS)
        handed, patched = self.requests_handed_over()
        with patched:
            code, out, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, out, err), (0, "", ""))
        self.assertEqual(handed, [{"uuid": UUID_A, "keys": KEYS}])
        self.assertEqual(self.stubs.argvs("systemctl"), [["systemctl", "--no-ask-password", "start", "vekrona-vpn-apply@connect-%d.service" % self.uid]])
        self.assertFalse(Path(vpn.request_path(self.uid)).exists())

    def test_connect_to_a_mullvad_country_picks_a_relay_of_it_with_the_device_of_the_keyring(self):
        handed, patched = self.requests_handed_over()
        with patched:
            code, _, err = self.run_cli("connect", "mullvad", "nl")
        self.assertEqual((code, err), (0, ""))
        device = self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID)
        self.assertEqual(handed, [{"vendor": "mullvad", "relay": relay_dict(), "device": device}])
    def test_connect_to_mullvad_without_a_device_in_the_keyring_says_not_logged_in_and_starts_nothing(self):
        self.stubs.keyring_file.write_text("[]")
        code, out, err = self.run_cli("connect", "mullvad", "nl")
        self.assertEqual((code, err), (1, "vekrona-vpn: Mullvad is not logged in\n"))
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_a_locked_keyring_fails_connect_with_keyring_locked_before_anything_is_armed(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.lock(True)
        code, out, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("keyring locked", err)
        self.assertEqual(self.stubs.called("nft"), [])
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_a_missing_item_that_secret_tool_reports_with_a_warning_is_still_missing(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.behave("secret-tool", ["lookup"], rc=1, stderr="(gcr-prompter) warning: something\n")
        code, _, err = self.run_cli("connect", UUID_A)
        self.assertEqual(code, 1)
        self.assertIn("the keyring holds no config-key for %s" % CONFIG_ID, err)

    def test_a_connection_without_a_key_in_an_unlocked_keyring_says_no_key_is_stored(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        code, out, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("the keyring holds no config-key for %s" % CONFIG_ID, err)
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_forgetting_without_a_key_in_an_unlocked_keyring_succeeds(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        code, _, err = self.run_cli("forget", UUID_A)
        self.assertEqual((code, err), (0, ""))

    def test_a_keyring_whose_lock_cannot_be_asked_fails_instead_of_reading_as_a_missing_item(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.behave("busctl", [], rc=1, stderr="Failed to connect to bus\n")
        code, _, err = self.run_cli("connect", UUID_A)
        self.assertEqual(code, 1)
        self.assertIn("cannot ask the keyring whether it is locked", err)
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_connecting_seals_a_key_that_is_still_in_a_keyfile_before_it_connects(self):
        self.unsealed_connection()
        handed, patched = self.requests_handed_over()
        with patched:
            code, _, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(handed, [{"phase": "export"}, {"phase": "strip", "uuids": [UUID_A]}, {"uuid": UUID_A, "keys": KEYS}])

    def test_connecting_to_a_profile_bound_to_another_interface_is_refused_before_the_keyring_is_touched(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.nm_peer_of(UUID_A, "203.0.113.9:51820", interface="wp2c-probe")
        code, out, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(err, "vekrona-vpn: %s is bound to wp2c-probe, not vvpn0; vekrona-vpn connects only profiles it imported\n" % CONFIG_ID)
        self.assertEqual(self.stubs.called("secret-tool"), [])
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_forgetting_a_configuration_removes_its_key_from_the_keyring(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.seed(secrets.CONFIG_KEY, CONFIG_ID, KEYS)
        code, _, err = self.run_cli("forget", UUID_A)
        self.assertEqual((code, err), (0, ""))
        self.assertIsNone(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID))

    def test_forgetting_names_the_key_it_could_not_clear(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.seed(secrets.CONFIG_KEY, CONFIG_ID, KEYS)
        self.stubs.lock(True)
        code, _, err = self.run_cli("forget", UUID_A)
        self.assertEqual(code, 1)
        self.assertIn("secret-tool clear application vekrona-vpn kind config-key id %s" % CONFIG_ID, err)

    def test_forgetting_a_mullvad_connection_keeps_the_device_the_account_shares(self):
        self.nm_lists([(UUID_B, "vekrona-vpn/mullvad/NL/nl-ams-wg-001")])
        code, _, err = self.run_cli("forget", UUID_B)
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID), DEVICE_DOC)

    def test_connecting_asks_mullvad_for_the_relay_list_only_when_the_cache_is_old_or_unusable(self):
        def relay_list_requests():
            return len(self.api.requests_to("GET", "/app/v1/relays"))

        self.run_cli("connect", "mullvad", "nl")
        self.run_cli("connect", "mullvad", "se")
        self.assertEqual(relay_list_requests(), 1)
        old = time.time() - mullvad.RELAYS_MAX_AGE_SEC - 60
        os.utime(self.relay_cache, (old, old))
        self.run_cli("connect", "mullvad", "nl")
        self.assertEqual(relay_list_requests(), 2)
        self.relay_cache.write_text("{not json")
        code, _, err = self.run_cli("connect", "mullvad", "nl")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(relay_list_requests(), 3)
        self.assertEqual(sorted(mullvad.read_cache(str(self.relay_cache))["names"]), ["nl", "se"])

    def test_list_with_a_cache_that_cannot_be_used_and_no_way_to_reach_mullvad_still_lists_the_other_vendors(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/mullvad/NL/nl-ams-wg-001"), (UUID_B, "vekrona-vpn/other/DE/de-1")])
        self.relay_cache.parent.mkdir(parents=True)
        self.relay_cache.write_text("{not json")
        with mock.patch.object(mullvad, "MULLVAD_API", unused_port_base()):
            code, out, err = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertIn("unusable", err)
        vendors = json.loads(out)["vendors"]
        self.assertEqual((vendors[0]["countries"], vendors[2]["countries"][0]["code"]), ([], "DE"))

    def test_list_without_an_account_and_a_cache_that_cannot_be_used_still_lists(self):
        self.nm_lists([(UUID_B, "vekrona-vpn/other/DE/de-1")])
        self.relay_cache.parent.mkdir(parents=True)
        self.relay_cache.write_text("{not json")
        code, out, err = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertIn("unusable", err)
        self.assertEqual(json.loads(out)["vendors"][2]["countries"][0]["code"], "DE")

    def test_connect_to_a_country_that_is_not_given_as_a_code_says_which_country_it_took_it_for(self):
        for query, said in (("Netherlands", "Netherlands (NL)"), ("swe", "Sweden (SE)"), ("holland", "Netherlands (NL)")):
            handed, patched = self.requests_handed_over()
            with patched:
                code, out, err = self.run_cli("connect", "mullvad", query)
            with self.subTest(query=query):
                self.assertEqual((code, out, err), (0, "", "vekrona-vpn: using %s\n" % said))
                self.assertEqual(handed[0]["relay"]["country"], said[-3:-1].lower())

    def test_connect_to_a_country_mullvad_does_not_have_fails_with_one_line_and_starts_nothing(self):
        for country in ("Atlantis", "", "de", "fr"):
            code, out, err = self.run_cli("connect", "mullvad", country)
            with self.subTest(country=country):
                self.assertEqual((code, out), (1, ""))
                self.assertEqual(len(err.strip().splitlines()), 1)
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_connect_with_an_empty_relay_list_fails(self):
        self.api.answer("GET", "/app/v1/relays", {"locations": {}, "wireguard": {"relays": []}})
        code, _, err = self.run_cli("connect", "mullvad", "nl")
        self.assertEqual(code, 1)
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_connect_with_a_wrong_argument_fails_before_anything_is_handed_over(self):
        for argv in (("connect", "mullvad"), ("connect", UUID_A, "nl"), ("connect", "../"), ("connect", ""), ("connect", "lizard"),
                     ("connect", UUID_A.upper()), ("connect", "-1"), ("forget", "../"), ("forget", "")):
            code, out, err = self.run_cli(*argv)
            with self.subTest(argv=argv):
                self.assertNotEqual(code, 0)
        self.assertEqual(self.stubs.called("systemctl"), [])
        self.assertFalse(Path(vpn.request_path(self.uid)).exists())

    def test_a_helper_that_fails_gives_its_own_line_and_the_request_is_still_taken_back(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.seed(secrets.CONFIG_KEY, CONFIG_ID, KEYS)
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1, stderr="Job for x failed\n")
        self.helper_failure = "Mullvad is not logged in"
        code, out, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, out, err), (1, "", "vekrona-vpn: Mullvad is not logged in\n"))
        self.assertFalse(Path(vpn.request_path(self.uid)).exists())

    def test_a_failure_of_an_earlier_run_is_never_reported_for_this_one(self):
        vpn.record_receipt(self.uid, vpn.Receipt(OTHER_NONCE, "Mullvad is not logged in"))
        self.helper_leaves_a_receipt = False
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1, stderr="Failed to start x: Interactive authentication required.\n")
        code, out, err = self.run_cli("off")
        self.assertEqual((code, out), (1, ""))
        self.assertEqual(err, "vekrona-vpn: systemctl --no-ask-password start failed with status 1: Failed to start x: Interactive "
                              "authentication required. (the helper did not serve this request)\n")

    def test_a_start_that_failed_after_the_helper_succeeded_says_so(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1, stderr="Connection timed out\n")
        code, _, err = self.run_cli("forget", UUID_A)
        self.assertEqual(code, 1)
        self.assertTrue(err.endswith("(the helper did serve this request)\n"), err)

    def test_a_receipt_that_cannot_be_read_is_said_with_the_failure_of_the_start(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1)
        self.helper_leaves_a_receipt = False
        (self.tmp / "run" / "vekrona-vpn").mkdir(parents=True)
        (self.tmp / "run" / "vekrona-vpn" / "served").write_text("a file where the receipts' directory belongs")
        code, _, err = self.run_cli("forget", UUID_A)
        self.assertEqual(code, 1)
        self.assertIn("cannot be read", err)

    def test_off_is_one_operation_of_the_helper_which_takes_the_tunnel_down_and_removes_the_kill_switch(self):
        handed, patched = self.requests_handed_over()
        with patched:
            code, out, err = self.run_cli("off")
        self.assertEqual((code, out, err), (0, "", ""))
        self.assertEqual(handed, [{}])
        self.assertEqual(self.stubs.argvs("systemctl"), [
            ["systemctl", "--no-ask-password", "start", "vekrona-vpn-apply@off-%d.service" % self.uid]])

    def test_a_start_that_merged_into_the_job_of_an_interrupted_call_fails_instead_of_pretending_to_succeed(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.seed(secrets.CONFIG_KEY, CONFIG_ID, KEYS)
        for command in (("off",), ("connect", UUID_A), ("forget", UUID_A)):
            vpn.record_receipt(self.uid, vpn.Receipt(OTHER_NONCE, None))  # the earlier job served the earlier client's request
            self.helper_leaves_a_receipt = False  # systemctl start succeeds by joining that job; nothing reads this call's request
            code, out, err = self.run_cli(*command)
            with self.subTest(command=command):
                self.assertEqual((code, out), (1, ""))
                self.assertEqual(err, "vekrona-vpn: another vekrona-vpn %s was still running; try again\n" % command[0])
                self.assertFalse(Path(vpn.request_path(self.uid)).exists())

    def test_off_that_the_helper_refuses_fails_with_its_message(self):
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1)
        self.helper_failure = "nmcli failed"
        code, _, err = self.run_cli("off")
        self.assertEqual((code, err), (1, "vekrona-vpn: nmcli failed\n"))

    def test_import_reads_the_files_and_hands_them_over_with_the_vendor(self):
        good = self.tmp / "NL-792.conf"
        good.write_text(PROTON_CONF)
        handed, patched = self.requests_handed_over()
        with patched:
            code, _, _ = self.run_cli("import", "--vendor", "other", str(good))
        self.assertEqual(code, 0)
        self.assertEqual(handed, [{"vendor": "other", "files": [{"file": "NL-792.conf", "text": PROTON_CONF}]}])
        self.assertEqual(self.stubs.argvs("systemctl")[0][-1], "vekrona-vpn-apply@import-%d.service" % self.uid)
        self.assertEqual(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID), KEYS)

    def test_import_names_the_bad_file_not_its_content_and_starts_nothing(self):
        good = self.tmp / "ok.conf"
        good.write_text(PROTON_CONF)
        cases = {"empty.conf": "", "host.conf": PROTON_CONF.replace("203.0.113.9", "vpn.example.com"),
                 "nodns.conf": conf_without("DNS"), "garbage.conf": SECRET_WORD * 3, "huge.conf": "#" * (vpn.MAX_CONF_BYTES + 1)}
        for name, text in cases.items():
            bad = self.tmp / name
            bad.write_text(text)
            code, out, err = self.run_cli("import", "--vendor", "other", str(good), str(bad))
            with self.subTest(name=name):
                self.assertEqual(code, 1)
                self.assertTrue(err.startswith("vekrona-vpn: %s: " % name), err)
                self.assertNotIn(SECRET_WORD, err)
        code, _, err = self.run_cli("import", "--vendor", "other", str(self.tmp / "missing.conf"))
        self.assertEqual(code, 1)
        self.assertIn("missing.conf: No such file", err)
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_import_for_a_vendor_that_has_no_files_is_refused(self):
        self.assertNotEqual(self.run_cli("import", "--vendor", "mullvad", "x.conf")[0], 0)
        self.assertNotEqual(self.run_cli("import", "x.conf")[0], 0)

    def test_import_through_the_chooser_does_nothing_when_it_is_cancelled(self):
        with mock.patch.object(cli.vekrona_cli, "choose_paths", return_value=[]) as chooser:
            code, _, _ = self.run_cli("import", "--vendor", "other")
        self.assertEqual(code, 0)
        chooser.assert_called_once()
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_import_through_a_chooser_that_is_missing_fails_with_its_reason(self):
        with mock.patch.object(cli.vekrona_cli, "choose_paths", side_effect=cli.vekrona_cli.PortalError("no portal")):
            code, _, err = self.run_cli("import", "--vendor", "other")
        self.assertEqual((code, err), (1, "vekrona-vpn: no portal\n"))

    def test_logging_in_registers_a_device_and_hands_only_its_key_and_addresses_to_the_helper_and_keeps_both_in_the_keyring(self):
        # The device the keyring held (the CLI setup seeds one without an id) is removed from the account by its public key.
        self.api.answer("GET", "/accounts/v1/devices", [{"id": "old1", "name": "old laptop", "pubkey": KEY_PUBLIC}])
        self.api.answer("DELETE", "/accounts/v1/devices/old1", None, status=204)
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("POST", "/accounts/v1/devices", {"id": "d1", "name": "brave koala", "ipv4_address": "10.66.0.5/32",
                                                         "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"}, status=201)
        handed, patched = self.requests_handed_over()
        with patched, mock.patch.object(sys, "stdin", io.StringIO("1234 5678 9012 3456\n")):
            code, out, err = self.run_cli("mullvad", "login")
        self.assertEqual((code, out, err), (0, "", ""))
        (doc,) = handed
        self.assertEqual(doc["device"], {"private_key": KEY_PRIVATE, "ipv4_address": "10.66.0.5/32", "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"})
        self.assertIn(doc["relay"]["hostname"], ("nl-ams-wg-001", "se-got-wg-001"))
        self.assertEqual(self.api.requests_to("POST", "/auth/v1/token")[0]["body"], {"account_number": "1234567890123456"})
        self.assertNotIn("1234567890123456", json.dumps(doc))
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_ACCOUNT, secrets.MULLVAD_ACCOUNT_ID), {"number": "1234567890123456"})
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID), {**DEVICE_DOC, "device_id": "d1"})
        # Only the keyring and the call log hold the account and the key. behaviors.json holds the fake tools' own answers.
        for path in self.tmp.rglob("*"):
            if path.is_file() and path.name not in ("keyring.json", "calls.jsonl", "behaviors.json"):
                text = path.read_text(errors="replace")
                self.assertNotIn("1234567890123456", text, str(path))
                self.assertNotIn(KEY_PRIVATE, text, str(path))
        self.assertEqual(self.api.requests_to("DELETE", "/accounts/v1/devices/d1"), [])
        self.assertEqual(len(self.api.requests_to("DELETE", "/accounts/v1/devices/old1")), 1)

    def test_logging_in_again_removes_the_device_the_keyring_held_before(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("POST", "/accounts/v1/devices", {"id": "d1", "name": "brave koala", "ipv4_address": "10.66.0.5/32",
                                                         "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"}, status=201)
        self.api.answer("DELETE", "/accounts/v1/devices/old1", None, status=204)
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, {**DEVICE_DOC, "private_key": key(7), "device_id": "old1"})
        with mock.patch.object(sys, "stdin", io.StringIO("1234567890123456\n")):
            code, _, err = self.run_cli("mullvad", "login")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(len(self.api.requests_to("DELETE", "/accounts/v1/devices/old1")), 1)
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID)["device_id"], "d1")

    def test_a_locked_keyring_stops_a_login_before_anything_is_registered_at_mullvad(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.stubs.lock(True)
        with mock.patch.object(sys, "stdin", io.StringIO("1234567890123456\n")):
            code, _, err = self.run_cli("mullvad", "login")
        self.assertEqual(code, 1)
        self.assertIn("keyring locked", err)
        self.assertEqual(self.api.requests_to("POST", "/accounts/v1/devices"), [])
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_a_login_the_helper_refuses_puts_the_old_device_and_account_back_and_removes_the_new_device(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("POST", "/accounts/v1/devices", {"id": "d1", "name": "brave koala", "ipv4_address": "10.66.0.5/32",
                                                         "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"}, status=201)
        self.api.answer("DELETE", "/accounts/v1/devices/d1", None, status=204)
        old_device = {**DEVICE_DOC, "private_key": key(7), "device_id": "old1"}
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, old_device)
        self.stubs.seed(secrets.MULLVAD_ACCOUNT, secrets.MULLVAD_ACCOUNT_ID, {"number": "9999999999999999"})
        code, _, err = self.login_that_the_helper_refuses()
        self.assertEqual((code, err), (1, "vekrona-vpn: boom\n"))
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID), old_device)
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_ACCOUNT, secrets.MULLVAD_ACCOUNT_ID), {"number": "9999999999999999"})
        self.assertEqual(len(self.api.requests_to("DELETE", "/accounts/v1/devices/d1")), 1)
        self.assertEqual(self.api.requests_to("DELETE", "/accounts/v1/devices/old1"), [])

    def test_logging_out_removes_the_device_forgets_the_mullvad_connections_and_clears_the_keyring(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("DELETE", "/accounts/v1/devices/d1", None, status=204)
        self.stubs.seed(secrets.MULLVAD_ACCOUNT, secrets.MULLVAD_ACCOUNT_ID, {"number": "1234567890123456"})
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, {**DEVICE_DOC, "device_id": "d1"})
        self.nm_lists([(UUID_B, "vekrona-vpn/mullvad/NL/nl-ams-wg-001"), (UUID_A, CONFIG_ID)])
        code, out, err = self.run_cli("mullvad", "logout")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.api.requests_to("POST", "/auth/v1/token")[0]["body"], {"account_number": "1234567890123456"})
        self.assertEqual(len(self.api.requests_to("DELETE", "/accounts/v1/devices/d1")), 1)
        self.assertEqual(self.stubs.argvs("systemctl"), [["systemctl", "--no-ask-password", "start", "vekrona-vpn-apply@forget-%d.service" % self.uid]])
        self.assertEqual(self.stubs.keyring(), [])

    def test_logging_out_without_an_account_item_asks_for_the_number(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("DELETE", "/accounts/v1/devices/d1", None, status=204)
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, {**DEVICE_DOC, "device_id": "d1"})
        self.nm_lists([])
        with mock.patch.object(sys, "stdin", io.StringIO("1234 5678 9012 3456\n")):
            code, _, err = self.run_cli("mullvad", "logout")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.api.requests_to("POST", "/auth/v1/token")[0]["body"], {"account_number": "1234567890123456"})
        self.assertIsNone(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID))

    def test_a_logout_whose_device_cannot_be_removed_changes_nothing(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("DELETE", "/accounts/v1/devices/d1", {"code": "INTERNAL"}, status=500)
        self.stubs.seed(secrets.MULLVAD_ACCOUNT, secrets.MULLVAD_ACCOUNT_ID, {"number": "1234567890123456"})
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, {**DEVICE_DOC, "device_id": "d1"})
        self.nm_lists([(UUID_B, "vekrona-vpn/mullvad/NL/nl-ams-wg-001")])
        code, _, err = self.run_cli("mullvad", "logout")
        self.assertEqual(code, 1)
        self.assertIn("cannot remove the device again", err)
        self.assertEqual(self.stubs.called("systemctl"), [])
        self.assertEqual(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID)["device_id"], "d1")

    def test_logging_out_of_a_device_stored_before_ids_were_kept_finds_it_by_its_public_key(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("GET", "/accounts/v1/devices", [{"id": "d7", "name": "old", "pubkey": KEY_PUBLIC},
                                                       {"id": "d8", "name": "other", "pubkey": KEY_RELAY}])
        self.api.answer("DELETE", "/accounts/v1/devices/d7", None, status=204)
        self.stubs.seed(secrets.MULLVAD_ACCOUNT, secrets.MULLVAD_ACCOUNT_ID, {"number": "1234567890123456"})
        self.stubs.seed(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID, DEVICE_DOC)
        self.nm_lists([])
        code, _, err = self.run_cli("mullvad", "logout")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(len(self.api.requests_to("DELETE", "/accounts/v1/devices/d7")), 1)
        self.assertEqual(self.api.requests_to("DELETE", "/accounts/v1/devices/d8"), [])
        self.assertIsNone(self.stubs.stored(secrets.MULLVAD_DEVICE, secrets.MULLVAD_DEVICE_ID))

    def test_importing_a_file_stores_its_key_under_the_id_of_the_connection_the_helper_made(self):
        good = self.tmp / "NL-792.conf"
        good.write_text(PROTON_CONF)
        code, _, _ = self.run_cli("import", "--vendor", "other", str(good))
        self.assertEqual(code, 0)
        self.assertEqual(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID), KEYS)

    def test_an_import_that_the_helper_refuses_puts_the_keyring_back_and_keeps_the_old_key_of_its_id(self):
        first, second = self.tmp / "NL-792.conf", self.tmp / "DE-1.conf"
        first.write_text(PROTON_CONF)
        second.write_text(PROTON_CONF)
        self.stubs.seed(secrets.CONFIG_KEY, CONFIG_ID, {"private_key": key(9)})
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1)
        self.helper_failure = "file 2: nmcli connection modify failed"
        code, _, err = self.run_cli("import", "--vendor", "other", str(first), str(second))
        self.assertEqual((code, err), (1, "vekrona-vpn: file 2: nmcli connection modify failed\n"))
        self.assertEqual(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID), {"private_key": key(9)})
        self.assertIsNone(self.stubs.stored(secrets.CONFIG_KEY, "vekrona-vpn/other/DE/DE-1"))

    def test_two_files_that_would_make_the_same_connection_are_refused_before_anything_is_stored(self):
        first, second = self.tmp / "NL-792.conf", self.tmp / "NL-792.CONF"
        first.write_text(PROTON_CONF)
        second.write_text(PROTON_CONF)
        code, _, err = self.run_cli("import", "--vendor", "other", str(first), str(second))
        self.assertEqual(code, 1)
        self.assertEqual(err, "vekrona-vpn: NL-792.conf and NL-792.CONF would both make the connection %s\n" % CONFIG_ID)
        self.assertEqual([item for item in self.stubs.keyring() if item["attributes"]["kind"] == secrets.CONFIG_KEY], [])
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_an_import_whose_keyring_is_locked_starts_nothing(self):
        good = self.tmp / "NL-792.conf"
        good.write_text(PROTON_CONF)
        self.stubs.lock(True)
        code, _, err = self.run_cli("import", "--vendor", "other", str(good))
        self.assertEqual(code, 1)
        self.assertIn("keyring locked", err)
        self.assertEqual(self.stubs.called("systemctl"), [])

    def unsealed_connection(self):
        """A configuration whose keyfile holds its key, as an earlier vekrona left it, with a helper that seals in place of the unit."""
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.behave("nmcli", ["-e", "no", "-g", "wireguard.private-key-flags"], stdout="0 (none)\n")
        self.nm_read(UUID_A, SEAL_FIELDS, ["0 (none)", KEY_PRIVATE, "%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER,
                                           "10.2.0.2/32", ""], with_secrets=True)
        self.nm_read(UUID_A, ["wireguard.peers"], ["%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER], with_secrets=True)
        self.keyfile(UUID_A)
        self.during_helper = self.helper_seals

    def helper_seals(self):
        """The root helper's part of a seal, run here in place of the unit: the request of a seal has a phase, the others do not."""
        if "phase" in vpn.read_request(self.uid):
            helper.apply(vpn.instance_name("seal", self.uid))

    def test_sealing_moves_the_keys_of_the_keyfiles_to_the_keyring_and_takes_them_out(self):
        self.unsealed_connection()
        code, out, err = self.run_cli("seal")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID), KEYS)
        self.assertFalse(Path(vpn.sealed_path(self.uid)).exists())
        self.assertEqual(len(self.stubs.argvs("systemctl")), 2)
        self.assertNotIn(KEY_PRIVATE, out + err)

    def test_sealing_holds_the_users_lock_from_the_export_to_the_strip(self):
        self.unsealed_connection()
        held = []

        def probe_then_seal():
            with open(Path(vpn.user_dir(self.uid)) / vpn.LOCK_NAME, "a") as probe:
                try:
                    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held.append(False)
                except BlockingIOError:
                    held.append(True)
            self.helper_seals()

        self.during_helper = probe_then_seal
        code, _, err = self.run_cli("seal")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(held, [True, True])

    def test_a_key_that_cannot_be_checked_stays_in_its_keyfile_while_the_others_are_sealed(self):
        self.nm_lists([(UUID_A, CONFIG_ID), (UUID_B, "vekrona-vpn/other/??/sealed")])
        self.stubs.behave("nmcli", ["-e", "no", "-g", "wireguard.private-key-flags"], stdout="0 (none)\n")
        self.nm_read(UUID_A, SEAL_FIELDS, ["0 (none)", KEY_PRIVATE, "%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER,
                                           "10.2.0.2/32", ""], with_secrets=True)
        self.nm_read(UUID_B, SEAL_FIELDS, ["0 (none)", "lizard", "%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER,
                                           "10.2.0.3/32", ""], with_secrets=True)
        self.nm_read(UUID_A, ["wireguard.peers"], ["%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER], with_secrets=True)
        self.keyfile(UUID_A)
        self.keyfile(UUID_B, "[wireguard]\nprivate-key=lizard\n")
        self.during_helper = self.helper_seals
        code, _, err = self.run_cli("seal")
        self.assertEqual(code, 1)
        self.assertIn("vekrona-vpn/other/??/sealed", err)
        self.assertIn("not a WireGuard key", err)
        self.assertNotIn("lizard", err)
        self.assertEqual(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID), KEYS)
        self.assertEqual(len(self.stubs.argvs("systemctl")), 2)
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        self.assertEqual(modified["argv"][3], UUID_A)
        self.assertFalse(Path(vpn.sealed_path(self.uid)).exists())

    def test_sealing_with_every_key_sealed_already_starts_nothing(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        code, _, err = self.run_cli("seal")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.stubs.called("systemctl"), [])

    def test_a_seal_whose_store_and_whose_strip_both_fail_reports_both(self):
        self.unsealed_connection()
        self.stubs.behave("secret-tool", ["store"], rc=5, stderr="dismissed\n")

        def strip_refuses():
            request = vpn.read_request(self.uid)
            if request.get("phase") == "strip":
                vpn.record_receipt(self.uid, vpn.Receipt(request["nonce"], "strip refused"))
                raise vpn.VpnError("systemctl failed")
            self.helper_seals()

        self.during_helper = strip_refuses
        code, _, err = self.run_cli("seal")
        self.assertEqual(code, 1)
        self.assertIn("keyring locked or unavailable", err)
        self.assertIn("strip refused", err)

    def test_a_profile_that_keeps_its_key_flag_with_no_key_in_it_is_stripped_and_stores_nothing(self):
        self.nm_lists([(UUID_A, CONFIG_ID)])
        self.stubs.behave("nmcli", ["-e", "no", "-g", "wireguard.private-key-flags"], stdout="0 (none)\n")
        self.nm_read(UUID_A, SEAL_FIELDS, ["0 (none)", "", "%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER,
                                           "10.2.0.2/32", ""], with_secrets=True)
        self.nm_read(UUID_A, ["wireguard.peers"], ["%s allowed-ips=0.0.0.0/0;::/0; endpoint=203.0.113.9:51820" % KEY_PEER], with_secrets=True)
        self.keyfile(UUID_A)
        self.during_helper = self.helper_seals
        code, _, err = self.run_cli("seal")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual([item for item in self.stubs.keyring() if item["attributes"]["kind"] == secrets.CONFIG_KEY], [])
        (modified,) = self.stubs.called("nmcli", "connection", "modify")
        self.assertEqual(dict(zip(modified["argv"][4::2], modified["argv"][5::2]))["wireguard.private-key-flags"], "2")

    def test_a_seal_whose_keyfile_still_holds_a_key_fails_and_the_key_stays_in_the_keyring(self):
        self.unsealed_connection()
        self.keyfile(UUID_A, "[wireguard]\nprivate-key=%s\n" % KEY_PRIVATE)
        code, _, err = self.run_cli("seal")
        self.assertEqual(code, 1)
        self.assertIn("still holds a key", err)
        self.assertNotIn(KEY_PRIVATE, err)
        self.assertEqual(self.stubs.stored(secrets.CONFIG_KEY, CONFIG_ID), KEYS)
        self.assertFalse(Path(vpn.sealed_path(self.uid)).exists())



    def test_logging_in_with_a_refused_account_or_a_bad_number_starts_nothing(self):
        self.api.answer("POST", "/auth/v1/token", {"code": "INVALID_ACCOUNT"}, status=400)
        with mock.patch.object(sys, "stdin", io.StringIO("1234567890123456\n")):
            self.assertEqual(self.run_cli("mullvad", "login")[0], 1)
        with mock.patch.object(sys, "stdin", io.StringIO("not a number\n")):
            self.assertEqual(self.run_cli("mullvad", "login")[0], 1)
        with mock.patch.object(sys, "stdin", io.StringIO("")):
            self.assertEqual(self.run_cli("mullvad", "login")[0], 1)
        self.assertEqual(self.stubs.called("systemctl"), [])
        self.assertEqual(self.api.requests_to("POST", "/accounts/v1/devices"), [])

    def login_that_the_helper_refuses(self):
        self.api.answer("POST", "/auth/v1/token", {"access_token": "TOKEN"})
        self.api.answer("POST", "/accounts/v1/devices", {"id": "d1", "name": "brave koala", "ipv4_address": "10.66.0.5/32",
                                                         "ipv6_address": "fc00:bbbb:bbbb:bb01::5/128"}, status=201)
        self.stubs.behave("systemctl", ["--no-ask-password", "start"], rc=1)
        self.helper_failure = "boom"
        with mock.patch.object(sys, "stdin", io.StringIO("1234567890123456\n")):
            return self.run_cli("mullvad", "login")

    def test_a_login_the_helper_refuses_removes_the_device_again(self):
        self.api.answer("DELETE", "/accounts/v1/devices/d1", None, status=204)
        code, _, err = self.login_that_the_helper_refuses()
        self.assertEqual((code, err), (1, "vekrona-vpn: boom\n"))
        self.assertEqual(len(self.api.requests_to("DELETE", "/accounts/v1/devices/d1")), 1)





    def test_a_login_the_helper_refuses_and_a_device_that_stays_says_which(self):
        self.api.answer("DELETE", "/accounts/v1/devices/d1", {"code": "INTERNAL"}, status=500)
        code, _, err = self.login_that_the_helper_refuses()
        self.assertEqual(code, 1)
        self.assertIn("boom", err)
        self.assertIn("brave koala", err)


if __name__ == "__main__":
    unittest.main()


# ---- Proton ---------------------------------------------------------------------------------------------------------------

SELECTOR = "SELECTORSECRETVALUE0123456789ABCD"  # the sign-in's bearer secret: 32 characters
SIGN_IN_PATH = "/auth/v4/sessions/forks/" + SELECTOR
USER_CODE = "ABCD1234"
SEED = bytes(range(1, 33))
SEED_B64 = base64.b64encode(SEED).decode()
PRIVATE_B64 = proton.private_key_text(SEED)  # the WireGuard private key of the seed: it reaches NetworkManager's stdin only
SESSION_ITEM = {"uid": "UID1", "access_token": "ACCESS1", "refresh_token": "REFRESH1"}
SESSION_ANSWER = {"UID": "UID1", "AccessToken": "ACCESS1", "RefreshToken": "REFRESH1"}
REFRESH_TIME = 1800000000  # 2027-01-15 08:00:00 UTC
CLOCK = 1790000000  # 2026-09-20 (the tests that look at the time): before the cache files the tests write, so they are young
TIMER = "vekrona-vpn-proton-renew-1790003600.timer"
PLAN_PLUS = {"VPN": {"MaxTier": 2, "PlanName": "plus"}}
PLAN_FREE = {"VPN": {"MaxTier": 0, "PlanName": "free"}}
# RFC 8032, section 7.1, test 1: the seed and the Ed25519 public key of it.
RFC8032_SEED = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
RFC8032_PUBLIC = bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")


def api_logical(name, country, tier, score, *, status=1, features=0, entry_ip="203.0.113.10", entry_country=None):
    """A logical server as Proton's list answers it, with one server (the entry is in the exit's country unless told otherwise)."""
    return {"Name": name, "EntryCountry": entry_country or country, "ExitCountry": country, "Tier": tier, "Features": features,
            "Score": score, "Status": status, "Servers": [{"EntryIP": entry_ip, "X25519PublicKey": key(6), "Status": 1, "Label": "1"}]}


LOGICALS = [
    api_logical("CH#3", "CH", 0, 5.0, entry_ip="203.0.113.20"),
    api_logical("NL#1", "NL", 0, 3.0, entry_ip="203.0.113.21"),
    api_logical("US#2", "US", 2, 0.5, entry_ip="203.0.113.22"),
    api_logical("NL#4", "NL", 2, 4.0, entry_ip="203.0.113.24"),
    api_logical("NL#5", "NL", 2, 1.0, status=0, entry_ip="203.0.113.25"),
    api_logical("NL#6", "NL", 2, 2.0, features=16, entry_ip="203.0.113.26"),
    api_logical("DE#1", "DE", 2, 0.0, entry_ip="203.0.113.27"),
    api_logical("NL#7", "NL", 3, 0.1, entry_ip="203.0.113.28"),
]


def certificate_answer(fingerprint=None, refresh_time=REFRESH_TIME):
    return {"ClientKeyFingerprint": proton.fingerprint(SEED) if fingerprint is None else fingerprint, "RefreshTime": refresh_time,
            "ExpirationTime": REFRESH_TIME + 86400}


def fake_clock():
    """A clock and a pause for await_session: the pause moves the clock on and is counted, so the wait of ten minutes takes no time."""
    now = [0.0]
    pauses = []

    def pause(seconds):
        pauses.append(seconds)
        now[0] += seconds

    return (lambda: now[0]), pause, pauses


def session_of(item):
    return proton.session_of_item(item)


class ProtonCoreTest(unittest.TestCase):
    def test_the_wireguard_key_of_a_seed_is_the_x25519_form_of_the_ed25519_public_key_of_the_same_seed(self):
        # Both keys multiply the base point by the same clamped scalar, and the X25519 public key is the Montgomery u-coordinate of
        # that point, u = (1 + y) / (1 - y) for the Edwards y-coordinate of the Ed25519 public key (RFC 7748, section 4.1).
        p = 2 ** 255 - 19
        y = int.from_bytes(RFC8032_PUBLIC, "little") & ((1 << 255) - 1)
        u = (1 + y) * pow(1 - y, p - 2, p) % p
        self.assertEqual(proton.x25519_public(proton.x25519_from_seed(RFC8032_SEED)), u.to_bytes(32, "little"))

    def test_a_seed_that_is_not_32_bytes_of_base64_is_refused(self):
        for bad in ({}, {"seed": "lizard"}, {"seed": base64.b64encode(bytes(31)).decode()}, {"seed": None}):
            with self.subTest(bad=str(bad)), self.assertRaises(vpn.VpnError):
                proton.seed_of_item(bad)

    def test_a_server_renders_a_configuration_the_connection_accepts_with_ipv6_only_when_the_server_has_it(self):
        for raw, ipv6 in ((LOGICALS[1], False), (LOGICALS[5], True)):
            logical = proton.logical_of_answer(raw)
            conf = vpn.parse_conf(proton.conf_text(logical, logical["servers"][0], SEED))
            self.assertEqual((conf.has_ipv6, conf.private_key), (ipv6, PRIVATE_B64))
            self.assertEqual(conf.endpoint, vpn.Endpoint(raw["Servers"][0]["EntryIP"], 51820))

    def test_the_choices_of_the_account_are_its_countries_or_its_free_server(self):
        catalog, left_out = proton.catalog_from_answers("plus", 2, LOGICALS)
        self.assertEqual(left_out, [])
        self.assertEqual(sorted(proton.countries_of(catalog)), ["ch", "de", "nl", "us"])
        free, _ = proton.catalog_from_answers("free", 0, LOGICALS)
        self.assertEqual(proton.countries_of(free), {"free": "Fastest free server (IPv4 only)"})
        with_ipv6, _ = proton.catalog_from_answers("free", 0, LOGICALS + [api_logical("NL#8", "NL", 0, 9.0, features=16)])
        self.assertEqual(proton.countries_of(with_ipv6), {"free": "Fastest free server"})

    def test_free_takes_the_fastest_tier_zero_server_whatever_its_country(self):
        catalog, _ = proton.catalog_from_answers("free", 0, LOGICALS)
        choice = proton.choose(catalog, "free")
        self.assertEqual((choice.country, choice.logical["name"]), ("FREE", "NL#1"))

    def test_a_country_takes_the_fastest_usable_server_of_its_tier(self):
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS)
        choice = proton.choose(catalog, "nl")
        self.assertEqual((choice.country, choice.logical["name"]), ("NL", "NL#6"))

    def test_secure_core_and_tor_servers_are_never_chosen_for_a_country(self):
        extra = [api_logical("SC#1", "NL", 2, 0.1, entry_country="CH"), api_logical("SC#2", "NL", 2, 0.05, features=1),
                 api_logical("TOR#1", "NL", 2, 0.2, features=2)]
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS + extra)
        self.assertEqual(proton.choose(catalog, "nl").logical["name"], "NL#6")

    def test_the_server_with_ipv6_wins_over_a_lower_score_without_it(self):
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS + [api_logical("P2P#1", "NL", 2, 0.3, features=4)])
        self.assertEqual(proton.choose(catalog, "nl").logical["name"], "NL#6")

    def test_a_country_with_only_ipv4_servers_serves_them_and_is_labelled(self):
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS + [api_logical("P2P#2", "IT", 2, 0.3, features=4)])
        self.assertEqual(proton.choose(catalog, "it").logical["name"], "P2P#2")
        self.assertTrue(proton.countries_of(catalog)["it"].endswith(proton.IPV4_ONLY))
        self.assertFalse(proton.countries_of(catalog)["nl"].endswith(proton.IPV4_ONLY))

    def test_a_country_without_a_usable_server_and_a_query_that_is_no_country_are_errors(self):
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS)
        with self.assertRaisesRegex(vpn.VpnError, "no server for JP"):
            proton.choose(catalog, "jp")
        for query in ("", "N", "NLD", "??", "FREEX", "Netherlands"):
            with self.subTest(query=query), self.assertRaisesRegex(vpn.VpnError, "Proton takes a country code"):
                proton.choose(catalog, query)

    def test_a_logical_server_whose_name_or_fields_are_not_plain_is_refused(self):
        good = proton.logical_of_answer(LOGICALS[1])
        for changed in ({"name": "NL#1\nPostUp = x"}, {"name": ""}, {"country": "FREE"}, {"country": "nl"}, {"entry_country": "??"},
                        {"status": "1"}, {"score": True}, {"servers": None}, {"features": 1.5},
                        {"servers": [{**good["servers"][0], "public_key": "lizard"}]}):
            with self.subTest(changed=str(changed)), self.assertRaises(vpn.VpnError):
                proton.validate_logical({**good, **changed})

    def test_a_logical_server_the_tool_does_not_know_is_left_out_and_said(self):
        catalog, left_out = proton.catalog_from_answers("plus", 2, [LOGICALS[1], {"Name": "NL#9"}])
        self.assertEqual((len(catalog["logicals"]), len(left_out)), (1, 1))

    def test_a_recorded_certificate_is_reused_only_for_its_netshield_and_while_it_has_an_hour_left(self):
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS)
        catalog["certificate"] = {"refresh_time": REFRESH_TIME, "expiration_time": CLOCK + 2 * 3600, "netshield": 1}
        self.assertEqual(proton.reusable_certificate(catalog, 1, CLOCK), proton.Certificate(REFRESH_TIME, CLOCK + 2 * 3600))
        self.assertIsNone(proton.reusable_certificate(catalog, 2, CLOCK))
        self.assertIsNone(proton.reusable_certificate(catalog, 1, CLOCK + 3600))
        catalog["certificate"] = None
        self.assertIsNone(proton.reusable_certificate(catalog, 1, CLOCK))
        catalog["certificate"] = {"refresh_time": 1, "expiration_time": 2, "netshield": 5}
        with self.assertRaisesRegex(vpn.VpnError, "NetShield level"):
            proton.validate_catalog(catalog)


class ProtonApiTest(unittest.TestCase):
    def setUp(self):
        self.api = ApiFixture()
        self.api.start()
        self.addCleanup(self.api.stop)
        patched = mock.patch.object(proton, "PROTON_API", self.api.base)
        patched.start()
        self.addCleanup(patched.stop)

    def test_the_sign_in_is_polled_every_five_seconds_until_the_code_is_entered(self):
        self.api.answer_in_turn("GET", SIGN_IN_PATH, [(422, {"Code": 2001}), (422, {"Code": 2001}), (200, SESSION_ANSWER)])
        now, pause, pauses = fake_clock()
        session = proton.await_session(SELECTOR, now=now, pause=pause)
        self.assertEqual((session.uid, pauses), ("UID1", [5, 5]))

    def test_the_sign_in_gives_up_after_ten_minutes_by_the_clock(self):
        self.api.answer("GET", SIGN_IN_PATH, {"Code": 2001}, status=422)
        now, pause, pauses = fake_clock()
        with self.assertRaisesRegex(vpn.VpnError, "sign-in timed out"):
            proton.await_session(SELECTOR, now=now, pause=pause)
        self.assertEqual(len(pauses), proton.SIGN_IN_TIMEOUT_SEC // proton.SIGN_IN_POLL_SEC)

    def test_an_error_of_the_sign_in_names_no_selector(self):
        self.api.answer("GET", SIGN_IN_PATH, None, status=500)
        with self.assertRaises(vpn.VpnError) as caught:
            proton.poll_fork(SELECTOR)
        self.assertNotIn(SELECTOR, str(caught.exception))

    def test_a_version_proton_no_longer_accepts_says_that_vekrona_needs_an_update(self):
        self.api.answer("GET", "/auth/v4/sessions/forks", {"Code": 5003}, status=422)
        with self.assertRaisesRegex(vpn.VpnError, "needs an update"):
            proton.start_fork()

    def test_a_sign_in_answer_without_a_selector_or_with_a_user_code_of_another_shape_is_refused(self):
        for answer in ({"UserCode": USER_CODE}, {"Selector": SELECTOR, "UserCode": "AB"}, {"Selector": SELECTOR, "UserCode": "ABCD-1234"}):
            with self.subTest(answer=str(answer)), self.assertRaises(vpn.VpnError):
                self.api.answer("GET", "/auth/v4/sessions/forks", answer)
                proton.start_fork()

    def test_a_redirect_answer_is_an_error(self):
        self.api.answer("GET", "/vpn/v2", None, status=302)
        with self.assertRaisesRegex(vpn.VpnError, "HTTP 302"):
            proton.plan_of(proton.Account(session_of(SESSION_ITEM), lambda: None, lambda session: None))

    def test_an_access_token_proton_refuses_is_renewed_once_stored_and_the_call_retried_with_the_renewed_session(self):
        self.api.answer_in_turn("GET", "/vpn/v2", [(401, None), (200, PLAN_PLUS)])
        self.api.answer("POST", "/auth/v4/refresh", {"UID": "UID1", "AccessToken": "ACCESS2", "RefreshToken": "REFRESH2"})
        saved = []
        account = proton.Account(session_of(SESSION_ITEM), lambda: None, saved.append)
        self.assertEqual(proton.plan_of(account), (2, "plus"))
        self.assertEqual(saved, [proton.Session("UID1", "ACCESS2", "REFRESH2")])
        self.assertEqual(self.api.requests_to("POST", "/auth/v4/refresh")[0]["body"]["RefreshToken"], "REFRESH1")
        self.assertEqual([r["authorization"] for r in self.api.requests_to("GET", "/vpn/v2")], ["Bearer ACCESS1", "Bearer ACCESS2"])

    def test_two_renewals_racing_with_the_same_refresh_token_renew_once_and_the_loser_adopts_the_stored_session(self):
        # The winner renews (its refresh answer is 200) and stores the result; the loser, still holding REFRESH1, is refused with 10013
        # and finds REFRESH2 in the keyring: it adopts that session and its retried call goes through.
        self.api.answer_in_turn("GET", "/vpn/v2", [(401, None), (200, PLAN_PLUS), (401, None), (200, PLAN_PLUS)])
        self.api.answer_in_turn("POST", "/auth/v4/refresh", [
            (200, {"UID": "UID1", "AccessToken": "ACCESS2", "RefreshToken": "REFRESH2"}), (422, {"Code": 10013})])
        keyring = [session_of(SESSION_ITEM)]
        winner = proton.Account(session_of(SESSION_ITEM), lambda: keyring[0], keyring.append)
        loser = proton.Account(session_of(SESSION_ITEM), lambda: keyring[-1], keyring.append)
        self.assertEqual(proton.plan_of(winner), (2, "plus"))
        self.assertEqual(proton.plan_of(loser), (2, "plus"))
        self.assertEqual(len(self.api.requests_to("POST", "/auth/v4/refresh")), 2)
        self.assertEqual(keyring[-1], proton.Session("UID1", "ACCESS2", "REFRESH2"))
        self.assertEqual(self.api.requests_to("GET", "/vpn/v2")[-1]["authorization"], "Bearer ACCESS2")

    def test_a_refusal_of_a_refresh_token_the_keyring_still_holds_ends_the_session(self):
        self.api.answer_in_turn("GET", "/vpn/v2", [(401, None)])
        self.api.answer("POST", "/auth/v4/refresh", {"Code": 10013}, status=422)
        account = proton.Account(session_of(SESSION_ITEM), lambda: session_of(SESSION_ITEM), lambda session: None)
        with self.assertRaises(proton.SessionEnded):
            proton.plan_of(account)

    def test_a_renewed_session_that_cannot_be_stored_says_the_session_is_lost(self):
        self.api.answer_in_turn("GET", "/vpn/v2", [(401, None), (200, PLAN_PLUS)])
        self.api.answer("POST", "/auth/v4/refresh", {"UID": "UID1", "AccessToken": "ACCESS2", "RefreshToken": "REFRESH2"})

        def refuse(session):
            raise vpn.VpnError("keyring locked")

        with self.assertRaisesRegex(vpn.VpnError, "session is lost: sign in again"):
            proton.plan_of(proton.Account(session_of(SESSION_ITEM), lambda: None, refuse))

    def test_a_certificate_for_another_key_is_refused_and_the_request_names_the_key_and_the_netshield_level(self):
        account = proton.Account(session_of(SESSION_ITEM), lambda: None, lambda session: None)
        self.api.answer("POST", "/vpn/v1/certificate", certificate_answer("bogus"))
        with self.assertRaisesRegex(vpn.VpnError, "another key"):
            proton.certificate(account, SEED, 1)
        self.api.answer("POST", "/vpn/v1/certificate", certificate_answer())
        certificate = proton.certificate(account, SEED, 2)
        self.assertEqual((certificate.refresh_time, certificate.expiration_time), (REFRESH_TIME, REFRESH_TIME + 86400))
        (request,) = self.api.requests_to("POST", "/vpn/v1/certificate")[1:]
        self.assertEqual(request["body"]["ClientPublicKey"], proton.ed25519_public_pem(SEED))
        self.assertEqual(request["body"]["Features"]["NetShieldLevel"], 2)


class ProtonTest(CliSandbox):
    """The Proton commands through the CLI, with Proton's API as a local fixture and the keyring as the stubs keep it."""

    def setUp(self):
        super().setUp()
        patched = mock.patch.object(proton, "PROTON_API", self.api.base)
        patched.start()
        self.addCleanup(patched.stop)
        # No sign-in waits unless a test says so. The renewal timers are whatever `list-units` says (none unless a test says so).
        self.stubs.behave("systemctl", ["--user", "is-active"], rc=3)
        self.stubs.seed(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID, SESSION_ITEM)
        self.stubs.seed(secrets.PROTON_KEY, secrets.PROTON_KEY_ID, {"seed": SEED_B64})
        self.api.answer("GET", "/vpn/v2", PLAN_PLUS)
        self.api.answer("GET", "/vpn/v1/logicals", {"LogicalServers": LOGICALS})
        self.api.answer("POST", "/vpn/v1/certificate", certificate_answer())

    @contextlib.contextmanager
    def fake_time(self):
        """time.monotonic and time.sleep of the sign-in's unit: the clock moves only when the wait asks, and nothing sleeps."""
        now, pause, pauses = fake_clock()
        with mock.patch("time.monotonic", now), mock.patch("time.sleep", pause):
            yield pauses

    @contextlib.contextmanager
    def clock_at(self, now):
        with mock.patch("time.time", lambda: now):
            yield

    def start_sign_in(self):
        """`proton login` with an empty keyring: the code is shown (notification 42) and the selector is left for the unit."""
        self.stubs.keyring_file.write_text("[]")
        self.stubs.behave("notify-send", ["--print-id"], stdout="42\n")
        self.api.answer("GET", "/auth/v4/sessions/forks", {"Selector": SELECTOR, "UserCode": USER_CODE})
        self.api.answer("GET", SIGN_IN_PATH, SESSION_ANSWER)
        self.assertEqual(self.run_cli("proton", "login"), (0, USER_CODE + "\n", ""))

    def systemd_run_unit(self, ending):
        """The one systemd-run call whose argv ends with `ending` (the order of the calls is not the point)."""
        (call,) = [call for call in self.stubs.called("systemd-run") if call["argv"][-len(ending):] == ending]
        return call

    def browser_unit(self):
        return self.systemd_run_unit(["xdg-open", proton.SIGN_IN_URL])

    def await_unit(self):
        return self.systemd_run_unit(["proton", "await"])

    def connect(self, *argv):
        handed, patched = self.requests_handed_over()
        with patched:
            code, _, err = self.run_cli("connect", "proton", *argv)
        return code, err, handed

    def write_catalog(self, certificate=None):
        """The catalog cache as a sign-in leaves it, recording `certificate` (its three fields, or None)."""
        catalog, _ = proton.catalog_from_answers("plus", 2, LOGICALS)
        catalog["certificate"] = certificate
        vpn.write_cache(cli.proton_catalog_path(), catalog)

    def assert_no_secret_leaks(self, *texts):
        """No file, output, argument or environment of the run holds a secret of the account. The keyring file keeps the items, which is
        what it is for. The stdin of secret-tool is the keyring's own input, and the stdin of nmcli carries a connection's private key to
        NetworkManager: neither is looked at. Every other stdin is."""
        words = [SELECTOR, "UID1", "ACCESS1", "ACCESS2", "REFRESH1", "REFRESH2", SEED_B64, PRIVATE_B64]
        for text in texts:
            for word in words:
                self.assertNotIn(word, text)
        for call in self.stubs.calls():
            for word in words:
                self.assertNotIn(word, json.dumps(call["argv"]), call["tool"])
                self.assertNotIn(word, json.dumps(call["env"]), call["tool"])
                if call["tool"] not in ("secret-tool", "nmcli"):
                    self.assertNotIn(word, call["stdin"], call["tool"])
        for path in self.tmp.rglob("*"):
            if path.is_file() and path.name not in ("keyring.json", "behaviors.json", "calls.jsonl"):
                text = path.read_text(errors="replace")
                for word in words:
                    self.assertNotIn(word, text, str(path))

    def test_a_sign_in_keeps_the_session_and_the_seed_and_no_selector_or_token_reaches_an_argument_or_a_file(self):
        self.start_sign_in()
        self.assertEqual(self.await_unit()["argv"][-2:], ["proton", "await"])
        code, out, err = self.run_cli("proton", "await")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID), SESSION_ITEM)
        seed = base64.b64decode(self.stubs.stored(secrets.PROTON_KEY, secrets.PROTON_KEY_ID)["seed"])
        self.assertEqual(len(seed), 32)
        self.assertIn(["notify-send", "--app-name=vekrona", "--replace-id=42", "VPN", "Signed in to Proton (plus)"],
                      self.stubs.argvs("notify-send"))
        self.assertFalse(Path(cli.login_path(self.uid)).exists())
        self.assert_no_secret_leaks(out, err)

    def test_a_second_sign_in_is_refused_while_the_first_waits(self):
        self.stubs.behave("systemctl", ["--user", "is-active", "--quiet", "vekrona-vpn-proton-login.service"], rc=0)
        code, _, err = self.run_cli("proton", "login")
        self.assertEqual((code, err), (1, "vekrona-vpn: a Proton sign-in is already waiting\n"))
        self.assertEqual(self.api.requests_to("GET", "/auth/v4/sessions/forks"), [])

    def test_a_sign_in_that_cannot_start_closes_its_notification_and_keeps_no_selector(self):
        self.stubs.behave("notify-send", ["--print-id"], stdout="42\n")
        self.api.answer("GET", "/auth/v4/sessions/forks", {"Selector": SELECTOR, "UserCode": USER_CODE})
        self.stubs.behave("systemd-run", [], rc=1, stderr="Failed to start unit\n")
        code, out, err = self.run_cli("proton", "login")
        self.assertEqual(code, 1)
        self.assertIn(["busctl", "--user", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                       "org.freedesktop.Notifications", "CloseNotification", "u", "42"], self.stubs.argvs())
        self.assertFalse(Path(cli.login_path(self.uid)).exists())
        self.assert_no_secret_leaks(out, err)

    def test_the_sign_in_is_polled_every_five_seconds_until_the_code_is_entered(self):
        self.start_sign_in()
        self.api.answer_in_turn("GET", SIGN_IN_PATH, [(422, {"Code": 2001}), (422, {"Code": 2001}), (200, SESSION_ANSWER)])
        with self.fake_time() as pauses:
            self.assertEqual(self.run_cli("proton", "await")[0], 0)
        self.assertEqual(pauses, [5, 5])
        self.assertEqual(len(self.api.requests_to("GET", SIGN_IN_PATH)), 3)

    def test_a_sign_in_the_person_never_completes_times_out_and_keeps_nothing(self):
        self.start_sign_in()
        self.api.answer("GET", SIGN_IN_PATH, {"Code": 2001}, status=422)
        with self.fake_time() as pauses:
            code, _, _ = self.run_cli("proton", "await")
        self.assertEqual((code, len(pauses)), (1, 120))
        self.assertIn(["notify-send", "--app-name=vekrona", "--replace-id=42", "VPN", "Proton sign-in failed: sign-in timed out"],
                      self.stubs.argvs("notify-send"))
        self.assertIsNone(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID))

    def test_a_sign_in_whose_catalog_cannot_be_had_keeps_neither_the_session_nor_the_seed_it_made(self):
        self.start_sign_in()
        self.api.answer("GET", "/vpn/v2", None, status=500)
        code, out, err = self.run_cli("proton", "await")
        self.assertEqual(code, 1)
        self.assertIsNone(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID))
        self.assertIsNone(self.stubs.stored(secrets.PROTON_KEY, secrets.PROTON_KEY_ID))
        self.assertIn(["notify-send", "--app-name=vekrona", "--replace-id=42", "VPN",
                       "Proton sign-in failed: read the Proton plan: HTTP 500; nothing of this sign-in was kept"],
                      self.stubs.argvs("notify-send"))
        self.assert_no_secret_leaks(out, err)

    def test_connecting_to_free_hands_the_fastest_free_server_and_its_key_to_the_helper(self):
        self.api.answer("GET", "/vpn/v2", PLAN_FREE)
        code, err, handed = self.connect("free")
        self.assertEqual((code, err), (0, ""))
        (doc,) = handed
        self.assertEqual((doc["vendor"], doc["id"]), ("proton", "vekrona-vpn/proton/FREE/signed-in"))
        self.assertEqual(doc["private_key"], PRIVATE_B64)
        conf = vpn.parse_conf(doc["conf"])
        self.assertEqual((conf.private_key, conf.endpoint), (doc["private_key"], vpn.Endpoint("203.0.113.21", 51820)))
        self.assertEqual(self.stubs.argvs("systemctl")[0][-1], "vekrona-vpn-apply@connect-%d.service" % self.uid)
        self.assertFalse(Path(vpn.request_path(self.uid)).exists())

    def test_connecting_to_a_country_hands_its_fastest_usable_server_with_the_ipv6_it_has_and_refuses_what_is_no_country(self):
        code, err, handed = self.connect("nl")
        self.assertEqual((code, err), (0, ""))
        (doc,) = handed
        self.assertEqual(doc["id"], "vekrona-vpn/proton/NL/signed-in")
        self.assertTrue(vpn.parse_conf(doc["conf"]).has_ipv6)
        self.assertEqual(self.run_cli("connect", "proton", "lizard")[0], 1)

    def test_a_certificate_for_another_key_stops_connecting_before_the_helper_starts(self):
        self.api.answer("POST", "/vpn/v1/certificate", certificate_answer("bogus"))
        code, err, handed = self.connect("nl")
        self.assertEqual(code, 1)
        self.assertIn("another key", err)
        self.assertEqual((handed, self.stubs.argvs("systemctl")), ([], []))

    def test_a_locked_keyring_stops_connecting_before_anything_is_asked_of_proton(self):
        self.stubs.lock(True)
        code, _, err = self.run_cli("connect", "proton", "nl")
        self.assertEqual((code, err.startswith("vekrona-vpn: keyring locked")), (1, True))
        self.assertEqual(self.api.requests, [])

    def test_a_session_that_proton_ended_is_forgotten_here_and_said(self):
        self.api.answer("GET", "/vpn/v2", None, status=401)
        self.api.answer("POST", "/auth/v4/refresh", {"Code": 10013}, status=422)
        code, _, err = self.run_cli("connect", "proton", "nl")
        self.assertEqual((code, err), (1, "vekrona-vpn: the Proton session has ended; sign in again\n"))
        self.assertIsNone(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID))
        self.assertFalse(Path(cli.proton_catalog_path()).exists())

    def test_a_renewed_session_is_stored_before_the_retry_and_the_renewed_one_is_used_after(self):
        self.api.answer_in_turn("GET", "/vpn/v2", [(401, None), (200, PLAN_PLUS)])
        self.api.answer("POST", "/auth/v4/refresh", {"UID": "UID1", "AccessToken": "ACCESS2", "RefreshToken": "REFRESH2"})
        code, err, _ = self.connect("nl")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID),
                         {"uid": "UID1", "access_token": "ACCESS2", "refresh_token": "REFRESH2"})
        self.assertEqual(self.api.requests_to("POST", "/auth/v4/refresh")[0]["body"]["RefreshToken"], "REFRESH1")
        self.assertEqual([r["authorization"] for r in self.api.requests_to("GET", "/vpn/v2")], ["Bearer ACCESS1", "Bearer ACCESS2"])
        self.assertEqual(self.api.requests_to("GET", "/vpn/v1/logicals")[0]["authorization"], "Bearer ACCESS2")
        self.assert_no_secret_leaks()

    def test_a_connect_with_a_recorded_certificate_that_is_good_makes_no_request_to_proton(self):
        self.write_catalog({"refresh_time": REFRESH_TIME, "expiration_time": CLOCK + 10 * 3600, "netshield": 1})
        with mock.patch.object(proton, "PROTON_API", unused_port_base()), self.clock_at(CLOCK):
            code, err, handed = self.connect("nl")
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(handed[0]["id"], "vekrona-vpn/proton/NL/signed-in")
        self.assertEqual(self.api.requests, [])

    def test_a_browser_is_started_through_a_unit_that_is_not_waited_for(self):
        self.stubs.behave("notify-send", ["--print-id"], stdout="42\n")
        self.api.answer("GET", "/auth/v4/sessions/forks", {"Selector": SELECTOR, "UserCode": USER_CODE})
        code, out, err = self.run_cli("proton", "login")
        self.assertEqual((code, out, err), (0, USER_CODE + "\n", ""))
        self.assertEqual(self.browser_unit()["argv"][-2:], ["xdg-open", proton.SIGN_IN_URL])
        self.assertEqual(self.await_unit()["argv"][-2:], ["proton", "await"])

    def test_a_browser_that_cannot_start_is_an_error_and_closes_the_notification(self):
        self.stubs.behave("notify-send", ["--print-id"], stdout="42\n")
        self.api.answer("GET", "/auth/v4/sessions/forks", {"Selector": SELECTOR, "UserCode": USER_CODE})
        self.stubs.behave("systemd-run", ["--user", "--collect", "--quiet", "xdg-open"], rc=1, stderr="Failed to start unit\n")
        code, _, err = self.run_cli("proton", "login")
        self.assertEqual(code, 1)
        self.assertTrue(err.startswith("vekrona-vpn: cannot start the browser: systemd-run --user --collect failed with status 1"), err)
        self.assertIn(["busctl", "--user", "call", "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                       "org.freedesktop.Notifications", "CloseNotification", "u", "42"], self.stubs.argvs())
        self.assertFalse(Path(cli.login_path(self.uid)).exists())

    def test_a_connect_that_needs_proton_while_the_vpn_blocks_it_says_to_turn_the_vpn_off(self):
        with mock.patch.object(proton, "PROTON_API", unused_port_base()):
            code, _, err = self.run_cli("connect", "proton", "nl")
        self.assertEqual((code, err), (1, "vekrona-vpn: Proton needs the network to issue a certificate: turn the VPN off, then connect\n"))
        self.assertEqual(self.stubs.argvs("systemctl"), [])

    def test_connecting_arms_one_renewal_at_refresh_time_and_replaces_the_ones_there_are(self):
        self.stubs.behave("systemctl", ["--user", "list-units"], stdout="%s loaded active waiting\n" % TIMER)
        code, err, _ = self.connect("nl")
        self.assertEqual((code, err), (0, ""))
        calls = self.stubs.argvs()
        stop = calls.index(["systemctl", "--user", "stop", TIMER])
        scheduled = index_starting(calls, ["systemd-run", "--user", "--collect", "--on-calendar=2027-01-15 08:00:00 UTC",
                                           "--unit=vekrona-vpn-proton-renew-%d" % REFRESH_TIME])
        self.assertLess(stop, scheduled)
        self.assertEqual(self.stubs.called("systemd-run")[0]["argv"][-2:], ["proton", "renew"])

    def test_a_refresh_time_that_has_passed_is_armed_a_minute_from_now(self):
        self.api.answer("POST", "/vpn/v1/certificate", certificate_answer(refresh_time=CLOCK - 500))
        with self.clock_at(CLOCK):
            code, err, _ = self.connect("nl")
        self.assertEqual((code, err), (0, ""))
        when = CLOCK + 60
        self.assertEqual(self.stubs.called("systemd-run")[0]["argv"][:4],
                         ["--user", "--collect", "--on-calendar=" + datetime.fromtimestamp(when, tz=timezone.utc).strftime(
                             "%Y-%m-%d %H:%M:%S UTC"), "--unit=vekrona-vpn-proton-renew-%d" % when])

    def test_a_renewal_that_runs_arms_the_next_one_without_stopping_itself(self):
        self.write_catalog({"refresh_time": REFRESH_TIME, "expiration_time": CLOCK + 3 * 3600, "netshield": 1})
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/NL#6")], active=[(UUID_A, "activated")])
        self.stubs.behave("systemctl", ["--user", "list-units"], stdout="%s loaded active\n" % TIMER)
        with self.clock_at(CLOCK):
            code, out, err = self.run_cli("proton", "renew")
        self.assertEqual((code, err), (0, ""))
        stops = [call["argv"][-1] for call in self.stubs.called("systemctl", "--user", "stop")]
        self.assertEqual(stops, [TIMER])
        self.assertIn("--unit=vekrona-vpn-proton-renew-%d" % REFRESH_TIME, self.stubs.called("systemd-run")[0]["argv"])
        (request,) = self.api.requests_to("POST", "/vpn/v1/certificate")
        self.assertEqual((request["body"]["ClientPublicKey"], request["body"]["Features"]["NetShieldLevel"]),
                         (proton.ed25519_public_pem(SEED), 1))
        recorded = json.loads(Path(cli.proton_catalog_path()).read_text())["certificate"]
        self.assertEqual(recorded, {"refresh_time": REFRESH_TIME, "expiration_time": REFRESH_TIME + 86400, "netshield": 1})
        self.assert_no_secret_leaks(out, err)

    def test_a_renewal_that_fails_tells_the_person_when_the_tunnel_stops_and_retries_once_in_half_an_hour(self):
        self.write_catalog({"refresh_time": REFRESH_TIME, "expiration_time": CLOCK + 3 * 3600, "netshield": 1})
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/NL#6")], active=[(UUID_A, "activated")])
        self.api.answer("POST", "/vpn/v1/certificate", None, status=500)
        with self.clock_at(CLOCK):
            code, _, _ = self.run_cli("proton", "renew")
        expiry = datetime.fromtimestamp(CLOCK + 3 * 3600).strftime("%H:%M")
        self.assertEqual(code, 1)
        self.assertIn(["notify-send", "--app-name=vekrona", "VPN", "Proton certificate could not be renewed: request a Proton certificate: "
                       "HTTP 500; the tunnel stops working at %s" % expiry], self.stubs.argvs("notify-send"))
        self.assertEqual([call["argv"][3] for call in self.stubs.called("systemd-run")], ["--unit=vekrona-vpn-proton-renew-%d" % (CLOCK + 1800)])

    def test_a_renewal_after_the_expiry_says_so_and_tries_no_more(self):
        self.write_catalog({"refresh_time": REFRESH_TIME, "expiration_time": CLOCK + 3 * 3600, "netshield": 1})
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/NL#6")], active=[(UUID_A, "activated")])
        self.api.answer("POST", "/vpn/v1/certificate", None, status=500)
        with self.clock_at(CLOCK + 4 * 3600):
            code, _, _ = self.run_cli("proton", "renew")
        self.assertEqual(code, 1)
        self.assertEqual(self.stubs.called("systemd-run"), [])
        self.assertTrue(any("stops working" in call["argv"][-1] for call in self.stubs.called("notify-send")))

    def test_a_renewal_with_no_proton_connection_up_does_nothing(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/NL#6")])
        self.assertEqual(self.run_cli("proton", "renew")[0], 0)
        self.assertEqual((self.api.requests, self.stubs.called("systemd-run")), ([], []))

    def test_off_stops_the_renewal_timers_and_no_service_while_a_proton_connection_is_there(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/signed-in")], active=[(UUID_A, "activated")])
        self.stubs.behave("systemctl", ["--user", "list-units"], stdout="%s loaded active\n" % TIMER)
        self.assertEqual(self.run_cli("off")[0], 0)
        self.assertEqual([call["argv"] for call in self.stubs.called("systemctl", "--user", "stop")], [["--user", "stop", TIMER]])

    def test_off_without_a_proton_connection_asks_systemd_for_no_timer(self):
        self.stubs.behave("systemctl", ["--user", "list-units"], stdout="%s loaded active\n" % TIMER)
        self.assertEqual(self.run_cli("off")[0], 0)
        self.assertEqual(self.stubs.called("systemctl", "--user", "list-units"), [])

    def test_forgetting_a_proton_connection_keeps_the_renewal_while_another_proton_connection_is_up(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/NL#6"), (UUID_B, "vekrona-vpn/proton/DE/DE#1")], active=[(UUID_B, "activated")])
        self.assertEqual(self.run_cli("forget", UUID_A)[0], 0)
        self.assertEqual(self.stubs.called("systemctl", "--user", "list-units"), [])

    def test_logout_ends_the_session_with_proton_and_clears_the_keyring_and_the_catalog(self):
        vpn.write_cache(cli.proton_catalog_path(), proton.catalog_from_answers("plus", 2, LOGICALS)[0])
        self.api.answer("DELETE", "/auth/v4", None)
        code, out, err = self.run_cli("proton", "logout")
        self.assertEqual((code, err), (0, ""))
        (request,) = self.api.requests_to("DELETE", "/auth/v4")
        self.assertEqual(request["authorization"], "Bearer ACCESS1")
        self.assertIsNone(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID))
        self.assertIsNone(self.stubs.stored(secrets.PROTON_KEY, secrets.PROTON_KEY_ID))
        self.assertFalse(Path(cli.proton_catalog_path()).exists())
        self.assert_no_secret_leaks(out, err)

    def test_logout_clears_both_items_and_the_catalog_even_when_proton_refuses_to_end_the_session(self):
        vpn.write_cache(cli.proton_catalog_path(), proton.catalog_from_answers("plus", 2, LOGICALS)[0])
        self.api.answer("DELETE", "/auth/v4", None, status=500)
        code, _, err = self.run_cli("proton", "logout")
        self.assertEqual(code, 1)
        self.assertIn("did not end the session", err)
        self.assertIsNone(self.stubs.stored(secrets.PROTON_SESSION, secrets.PROTON_SESSION_ID))
        self.assertIsNone(self.stubs.stored(secrets.PROTON_KEY, secrets.PROTON_KEY_ID))
        self.assertFalse(Path(cli.proton_catalog_path()).exists())

    def test_list_reads_the_catalog_cache_and_never_the_keyring_or_the_network(self):
        vpn.write_cache(cli.proton_catalog_path(), proton.catalog_from_answers("plus", 2, LOGICALS)[0])
        code, out, err = self.run_cli("list")
        proton_vendor = next(vendor for vendor in json.loads(out)["vendors"] if vendor["id"] == "proton")
        self.assertEqual(sorted(country["code"] for country in proton_vendor["countries"]), ["CH", "DE", "NL", "US"])
        self.assertEqual((code, self.stubs.called("secret-tool"), self.api.requests), (0, [], []))
        Path(cli.proton_catalog_path()).unlink()
        proton_vendor = next(vendor for vendor in json.loads(self.run_cli("list")[1])["vendors"] if vendor["id"] == "proton")
        self.assertEqual(proton_vendor["countries"], [])

    def test_netshield_is_kept_in_the_settings_and_status_shows_it_and_a_level_out_of_range_is_refused(self):
        self.assertEqual(self.run_cli("proton", "netshield", "2")[0], 0)
        self.assertEqual(json.loads(Path(cli.settings_path()).read_text()), {"proton": {"netshield": 2}})
        self.assertEqual(json.loads(self.run_cli("status")[1])["proton"], {"logged_in": False, "netshield": 2, "error": ""})
        self.assertEqual(self.run_cli("proton", "netshield", "3")[0], 2)

    def test_a_settings_file_that_cannot_be_read_is_said_by_status_and_the_status_still_answers(self):
        settings = Path(cli.settings_path())
        settings.parent.mkdir(parents=True, exist_ok=True)
        settings.write_text(json.dumps({"proton": {"netshield": 7}}))
        code, out, err = self.run_cli("status")
        self.assertEqual(code, 0)
        proton_status = json.loads(out)["proton"]
        self.assertIsNone(proton_status["netshield"])
        self.assertIn("NetShield level", proton_status["error"])

    def test_importing_a_proton_configuration_is_refused_since_proton_signs_in(self):
        conf = self.tmp / "NL-792.conf"
        conf.write_text(PROTON_CONF)
        self.assertEqual(self.run_cli("import", "--vendor", "proton", str(conf))[0], 2)
        self.assertEqual(self.stubs.argvs("systemctl"), [])

    def test_status_names_a_generated_connection_by_the_catalog_server_at_its_endpoint(self):
        self.write_catalog(None)
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/signed-in")], active=[(UUID_A, "activated")])
        self.nm_peer_of(UUID_A, "203.0.113.26:51820")
        self.write_state(True, UUID_A)
        self.assertEqual(json.loads(self.run_cli("status")[1])["connection"]["name"], "NL#6")
        self.assertEqual(self.stubs.called("secret-tool"), [])

    def test_status_shows_a_generated_connection_as_signed_in_when_no_server_of_the_catalog_matches(self):
        self.write_catalog(None)
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/signed-in")], active=[(UUID_A, "activated")])
        self.nm_peer_of(UUID_A, "198.51.100.99:51820")
        self.write_state(True, UUID_A)
        self.assertEqual(json.loads(self.run_cli("status")[1])["connection"]["name"], "signed-in")

    def test_connecting_to_a_proton_connection_by_its_uuid_is_refused_since_proton_connects_by_country(self):
        self.nm_lists([(UUID_A, "vekrona-vpn/proton/NL/NL#6")])
        code, _, err = self.run_cli("connect", UUID_A)
        self.assertEqual((code, err), (1, "vekrona-vpn: Proton connections are made by country: connect proton CC, or connect proton free\n"))


# ---- The output the shell reads -------------------------------------------------------------------------------------------

SHAPE = json.loads((REPO / "config" / "vekrona-shell" / "vpn-output.json").read_text())


def shape_problem(shape, value, path="$"):
    """The first way `value` does not have `shape`, or None. The shape language is that of config/vekrona-shell/vpn-output.json, which
    the shell's VpnState.qml reads with the same rules (its shapeProblem)."""
    if isinstance(shape, str):
        ok = {"boolean": isinstance(value, bool), "string": isinstance(value, str),
              "integer": isinstance(value, int) and not isinstance(value, bool)}[shape]
        return None if ok else "%s is not a %s" % (path, shape)
    if "enum" in shape:
        return None if any(type(value) is type(option) and value == option for option in shape["enum"]) else "%s is not one of %s" % (path, shape["enum"])
    if "nullable" in shape:
        return None if value is None else shape_problem(shape["nullable"], value, path)
    if "list" in shape:
        if not isinstance(value, list):
            return "%s is not a list" % path
        for index, item in enumerate(value):
            problem = shape_problem(shape["list"], item, "%s[%d]" % (path, index))
            if problem is not None:
                return problem
        return None
    if not isinstance(value, dict):
        return "%s is not an object" % path
    if sorted(value) != sorted(shape["object"]):
        return "%s has the keys %s, not %s" % (path, ", ".join(sorted(value)), ", ".join(sorted(shape["object"])))
    for key, sub_shape in shape["object"].items():
        problem = shape_problem(sub_shape, value[key], "%s.%s" % (path, key))
        if problem is not None:
            return problem
    return None


class ShellOutputTest(CliSandbox):
    """The output of `status` and `list`, from the real CLI through the stubs in every state the shell can meet, checked against the one
    shape description the shell reads (vpn-output.json)."""

    def arrange(self, catalog, listed, active, settings):
        shutil.rmtree(self.tmp / "cache", ignore_errors=True)
        shutil.rmtree(self.tmp / "config", ignore_errors=True)
        self.relay_cache.parent.mkdir(parents=True, exist_ok=True)
        self.relay_cache.write_text(json.dumps({"names": {"nl": "Netherlands"}, "relays": []}))
        if catalog is not None:
            vpn.write_cache(cli.proton_catalog_path(), catalog)
        if settings is not None:
            Path(cli.settings_path()).parent.mkdir(parents=True, exist_ok=True)
            Path(cli.settings_path()).write_text(json.dumps(settings))
        self.nm_lists(listed, active=active)
        self.nm_peer_of(UUID_A, "203.0.113.26:51820")
        self.write_state(bool(active), UUID_A if active else None)

    def test_status_and_list_have_the_shape_the_shell_reads_in_every_state(self):
        catalogs = {"no catalog": None,
                    "free": proton.catalog_from_answers("free", 0, LOGICALS)[0],
                    "paid": proton.catalog_from_answers("plus", 2, LOGICALS)[0]}
        connections = {
            "signed out": ([], []),
            "mullvad up": ([(UUID_A, "vekrona-vpn/mullvad/NL/nl-ams-wg-001")], [(UUID_A, "activated")]),
            "proton connecting": ([(UUID_A, "vekrona-vpn/proton/NL/signed-in")], [(UUID_A, "activating")]),
            "proton up": ([(UUID_A, "vekrona-vpn/proton/NL/signed-in")], [(UUID_A, "activated")]),
            "other configuration": ([(UUID_A, "vekrona-vpn/other/??/Office")], []),
        }
        settings_states = {"settings readable": None, "settings unreadable": {"proton": {"netshield": 7}}}
        for catalog_name, catalog in catalogs.items():
            for connection_name, (listed, active) in connections.items():
                for settings_name, settings in settings_states.items():
                    with self.subTest(catalog=catalog_name, connections=connection_name, settings=settings_name):
                        self.arrange(catalog, listed, active, settings)
                        for command, which in ((("status",), "status"), (("list",), "list")):
                            code, out, err = self.run_cli(*command)
                            self.assertEqual(code, 0, err)
                            self.assertIsNone(shape_problem(SHAPE[which], json.loads(out), which), which)
