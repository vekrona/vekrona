"""Test doubles for vekrona-vpn: stub system binaries and a local HTTP fixture for the providers' APIs (Mullvad and Proton).

The stubs stand in for nmcli, nft, ip, systemctl, getent, wg, secret-tool, busctl, notify-send, xdg-open and systemd-run. Each logs its argv and stdin as one JSON line (and the
content of the file an `nmcli ... file PATH` names, which the helper deletes right after the import) and then behaves as the
first matching rule of behaviors.json says (default: exit 0, no output). A rule matches when its argv is a prefix of the call's;
`times` limits how often it answers, and later `behave` calls win over earlier ones. secret-tool, when no rule answers, keeps
its items in keyring.json, next to the call log: `store` takes the secret on stdin, `lookup` and `clear` of a missing item exit 1
with no output (as on the VM), and the secret of an item is never written to the call log's argv. The collection is locked when
keyring.locked says so: then `lookup` and `clear` exit 1 with no output (a dismissed prompt), and `store` exits 1 with "Cannot create
an item in a locked collection". busctl answers the lock of the default collection from keyring.locked, as the Secret Service does.
nmcli refuses a `connection modify` of wireguard.peers that does not carry endpoint= and allowed-ips= (NetworkManager replaces the
whole peer with the value given)."""

import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import urlsplit

STUBBED_TOOLS = ("nmcli", "nft", "ip", "systemctl", "getent", "wg", "secret-tool", "busctl", "notify-send", "xdg-open", "systemd-run")

STUB_SOURCE = """#!{python} -S
import json, os, sys
tool = os.path.basename(sys.argv[0])
argv = sys.argv[1:]
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
entry = {{"tool": tool, "argv": argv, "stdin": stdin, "env": dict(os.environ)}}
if "file" in argv and argv.index("file") + 1 < len(argv):
    with open(argv[argv.index("file") + 1]) as handle:
        entry["file"] = handle.read()
with open(os.environ["VPN_STUB_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\\n")
with open(os.environ["VPN_STUB_BEHAVIORS"]) as handle:
    behaviors = json.load(handle)
if tool == "nmcli" and "modify" in argv and "wireguard.peers" in argv:
    peer = argv[argv.index("wireguard.peers") + 1]
    if "endpoint=" not in peer or "allowed-ips=" not in peer:
        sys.stderr.write("Error: the peer is replaced by the value given, which has no endpoint or allowed-ips\\n")
        sys.exit(2)
for rule in behaviors.get(tool, []):
    if argv[: len(rule["argv"])] == rule["argv"]:
        if rule.get("used", 0) == rule.get("times", -1):
            continue
        rule["used"] = rule.get("used", 0) + 1
        with open(os.environ["VPN_STUB_BEHAVIORS"], "w") as handle:
            json.dump(behaviors, handle)
        sys.stdout.write(rule.get("stdout", ""))
        sys.stderr.write(rule.get("stderr", ""))
        sys.exit(rule.get("rc", 0))
if tool == "busctl":
    with open(os.environ["VPN_STUB_LOCKED"]) as handle:
        sys.stdout.write("b " + handle.read().strip() + "\\n")
    sys.exit(0)
if tool == "secret-tool":
    # The attributes are the pairs after the verb (and after --label for store): application, kind and id.
    verb, rest = argv[0], [arg for arg in argv[1:] if not arg.startswith("--label=")]
    attributes = dict(zip(rest[0::2], rest[1::2]))
    keyring_path = os.environ["VPN_STUB_KEYRING"]
    with open(keyring_path) as handle:
        items = json.load(handle)
    with open(os.environ["VPN_STUB_LOCKED"]) as handle:
        locked = handle.read().strip() == "true"
    matching = [item for item in items if item["attributes"] == attributes]
    if verb == "store" and locked:
        sys.stderr.write("Cannot create an item in a locked collection\\n")
        sys.exit(1)
    if verb == "lookup":
        if locked or not matching:
            sys.exit(1)
        sys.stdout.write(matching[0]["secret"])
        sys.exit(0)
    if verb == "store":
        items = [item for item in items if item["attributes"] != attributes]
        items.append({{"attributes": attributes, "secret": stdin}})
    elif verb == "clear":
        if locked or not matching:
            sys.exit(1)
        items = [item for item in items if item["attributes"] != attributes]
    else:
        sys.exit(2)
    with open(keyring_path, "w") as handle:
        json.dump(items, handle)
sys.exit(0)
"""

class Stubs:
    """The stub binaries in one directory, their call log and their behaviors."""

    def __init__(self, directory: Path) -> None:
        self.bin = directory / "bin"
        self.bin.mkdir(parents=True)
        self.log = directory / "calls.jsonl"
        self.log.touch()
        self.keyring_file = directory / "keyring.json"
        self.keyring_file.write_text("[]")
        self.locked_file = directory / "keyring.locked"
        self.locked_file.write_text("false")
        self.behaviors_file = directory / "behaviors.json"
        self.behaviors: Dict[str, List[dict]] = {
            # No tor user, as on a machine without tor.
            "getent": [{"argv": ["passwd"], "rc": 2}],
            # An uplink with IPv4 and no IPv6 default route, the usual network; a test that needs another route table says so.
            "ip": [{"argv": ["-4", "route"], "stdout": "default via 192.0.2.254 dev eth0 proto dhcp metric 100\n"}],
        }
        self._save()
        for tool in STUBBED_TOOLS:
            path = self.bin / tool
            path.write_text(STUB_SOURCE.format(python=sys.executable))
            path.chmod(0o755)

    def _save(self) -> None:
        self.behaviors_file.write_text(json.dumps(self.behaviors))

    def behave(self, tool: str, argv: List[str], *, rc: int = 0, stdout: str = "", stderr: str = "",
               times: Optional[int] = None) -> None:
        """From now on `tool argv...` answers like this; later calls win."""
        rule = {"argv": argv, "rc": rc, "stdout": stdout, "stderr": stderr}
        if times is not None:
            rule["times"] = times
        self.behaviors.setdefault(tool, []).insert(0, rule)
        self._save()

    def env(self) -> Dict[str, str]:
        return {"VPN_STUB_LOG": str(self.log), "VPN_STUB_BEHAVIORS": str(self.behaviors_file),
                "VPN_STUB_KEYRING": str(self.keyring_file), "VPN_STUB_LOCKED": str(self.locked_file)}

    def lock(self, locked: bool = True) -> None:
        """Locks the keyring's default collection (or unlocks it): what the Secret Service then answers, for secret-tool and busctl."""
        self.locked_file.write_text("true" if locked else "false")

    def keyring(self) -> List[dict]:
        """Every item of the keyring: {"attributes": {...}, "secret": str}."""
        return json.loads(self.keyring_file.read_text())

    def stored(self, kind: str, ident: str) -> Optional[dict]:
        """The secret of the keyring item of `kind` and `ident`, decoded, or None."""
        for item in self.keyring():
            if item["attributes"] == {"application": "vekrona-vpn", "kind": kind, "id": ident}:
                return json.loads(item["secret"])
        return None

    def seed(self, kind: str, ident: str, value: dict) -> None:
        """Puts an item into the keyring as if an earlier call had stored it."""
        attributes = {"application": "vekrona-vpn", "kind": kind, "id": ident}
        items = [item for item in self.keyring() if item["attributes"] != attributes]
        items.append({"attributes": attributes, "secret": json.dumps(value)})
        self.keyring_file.write_text(json.dumps(items))

    def keyring_secrets(self) -> List[str]:
        """The secret text of every keyring item."""
        return [item["secret"] for item in self.keyring()]

    def calls(self, tool: Optional[str] = None) -> List[dict]:
        entries = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [e for e in entries if tool is None or e["tool"] == tool]

    def argvs(self, tool: Optional[str] = None) -> List[List[str]]:
        return [[e["tool"], *e["argv"]] for e in self.calls(tool)]

    def called(self, *prefix: str) -> List[dict]:
        """Every call whose tool and argv start with `prefix`."""
        return [c for c in self.calls() if [c["tool"], *c["argv"]][: len(prefix)] == list(prefix)]


class ApiFixture:
    """A local HTTP server with canned answers, recording every request. An answer is (status, body), or a list of them that are given
    in turn, the last one for good (a poll that is pending twice, then answers)."""

    def __init__(self) -> None:
        self.requests: List[dict] = []
        self.routes: Dict[tuple, tuple] = {}
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def _serve(self) -> None:
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length).decode() if length else ""
                path = urlsplit(self.path).path
                fixture.requests.append({"method": self.command, "path": path,
                                         "authorization": self.headers.get("Authorization"),
                                         "body": json.loads(raw) if raw else None})
                status, body = fixture.next_answer(self.command, path)
                payload = b"" if body is None else json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            do_GET = do_POST = do_DELETE = _serve

            def log_message(self, *args) -> None:
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def answer(self, method: str, path: str, body: object, status: int = 200) -> None:
        self.routes[(method, path)] = (status, body)

    def answer_in_turn(self, method: str, path: str, answers: List[tuple]) -> None:
        """`answers` is [(status, body), ...]: each request gets the next one, and the last one serves every request after it."""
        self.routes[(method, path)] = list(answers)

    def next_answer(self, method: str, path: str) -> tuple:
        answer = self.routes.get((method, path))
        if answer is None:
            return 404, {"code": "NOT_FOUND"}
        if not isinstance(answer, list):
            return answer
        if len(answer) > 1:
            return answer.pop(0)
        return answer[0]

    def requests_to(self, method: str, path: str) -> List[dict]:
        return [r for r in self.requests if (r["method"], r["path"]) == (method, path)]


def unused_port_base() -> str:
    """A base URL where nothing listens: connecting is refused at once, as the API is when the kill switch rejects."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return "http://127.0.0.1:%d" % sock.getsockname()[1]
