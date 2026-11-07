"""Test doubles for vekrona-vpn: stub system binaries and a local HTTP fixture for Mullvad's API.

The stubs stand in for nmcli, nft, systemctl, getent and wg. Each logs its argv and stdin as one JSON line (and the
content of the file an `nmcli ... file PATH` names, which the helper deletes right after the import) and then behaves as the
first matching rule of behaviors.json says (default: exit 0, no output). A rule matches when its argv is a prefix of the call's;
`times` limits how often it answers, and later `behave` calls win over earlier ones."""

import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import urlsplit

STUBBED_TOOLS = ("nmcli", "nft", "systemctl", "getent", "wg")

STUB_SOURCE = """#!{python} -S
import json, os, sys
tool = os.path.basename(sys.argv[0])
argv = sys.argv[1:]
stdin = "" if sys.stdin.isatty() else sys.stdin.read()
entry = {{"tool": tool, "argv": argv, "stdin": stdin}}
if "file" in argv and argv.index("file") + 1 < len(argv):
    with open(argv[argv.index("file") + 1]) as handle:
        entry["file"] = handle.read()
with open(os.environ["VPN_STUB_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\\n")
with open(os.environ["VPN_STUB_BEHAVIORS"]) as handle:
    behaviors = json.load(handle)
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
sys.exit(0)
"""

class Stubs:
    """The stub binaries in one directory, their call log and their behaviors."""

    def __init__(self, directory: Path) -> None:
        self.bin = directory / "bin"
        self.bin.mkdir(parents=True)
        self.log = directory / "calls.jsonl"
        self.log.touch()
        self.behaviors_file = directory / "behaviors.json"
        self.behaviors: Dict[str, List[dict]] = {
            # No tor user, as on a machine without tor.
            "getent": [{"argv": ["passwd"], "rc": 2}],
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
        return {"VPN_STUB_LOG": str(self.log), "VPN_STUB_BEHAVIORS": str(self.behaviors_file)}

    def calls(self, tool: Optional[str] = None) -> List[dict]:
        entries = [json.loads(line) for line in self.log.read_text().splitlines()]
        return [e for e in entries if tool is None or e["tool"] == tool]

    def argvs(self, tool: Optional[str] = None) -> List[List[str]]:
        return [[e["tool"], *e["argv"]] for e in self.calls(tool)]

    def called(self, *prefix: str) -> List[dict]:
        """Every call whose tool and argv start with `prefix`."""
        return [c for c in self.calls() if [c["tool"], *c["argv"]][: len(prefix)] == list(prefix)]


class ApiFixture:
    """A local HTTP server with canned answers, recording every request."""

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
                status, body = fixture.routes.get((self.command, path), (404, {"code": "NOT_FOUND"}))
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

    def requests_to(self, method: str, path: str) -> List[dict]:
        return [r for r in self.requests if (r["method"], r["path"]) == (method, path)]


def unused_port_base() -> str:
    """A base URL where nothing listens: connecting is refused at once, as the API is when the kill switch rejects."""
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return "http://127.0.0.1:%d" % sock.getsockname()[1]
