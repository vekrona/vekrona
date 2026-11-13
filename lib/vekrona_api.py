"""The HTTPS calls of the two providers of vekrona-vpn (Mullvad and Proton): one JSON request, with TLS verified against the system's
CA certificates, and one error for an answer that refuses or a network that fails. Runs as the user, never as the root helper.

An error names the request by the `name` its caller gives, never by its path: a path may hold a secret (Proton's sign-in poll)."""
import http.client
import json
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Sequence

import vekrona_vpn

HTTP_TIMEOUT_SEC = 15
USER_AGENT = "vekrona-vpn"


class NoRedirects(urllib.request.HTTPRedirectHandler):
    """Refuses to follow a redirect: the answer stays the 3xx it is, which is an ApiError for the caller. A redirect of a token-carrying
    request would send the token to whoever the redirect names."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


OPENER = urllib.request.build_opener(NoRedirects)


class ApiError(Exception):
    def __init__(self, message: str, status: Optional[int] = None, code: str = "") -> None:
        super().__init__(message)
        self.status = status
        self.code = code


def error_code(body: bytes) -> str:
    """The error code of an answer: `code` (Mullvad), `Code` (Proton, a number) or `type` (problem+json); "" when there is none."""
    try:
        doc = json.loads(body)
    except vekrona_vpn.JSON_ERRORS:
        return ""
    if not isinstance(doc, dict):
        return ""
    for key in ("code", "Code", "type"):
        value = doc.get(key)
        if isinstance(value, (str, int)) and not isinstance(value, bool):
            return str(value)
    return ""


def request_json(base: str, method: str, path: str, *, name: str, headers: Dict[str, str], body: Optional[object] = None,
                 expect: Sequence[int] = (200,)) -> Any:
    """One JSON request to `base` + `path`. Returns the parsed answer, or None for an empty one. `name` is what an error says the request
    is; `expect` the statuses of a good answer, any other is an ApiError."""
    all_headers = {"User-Agent": USER_AGENT, "Accept": "application/json", **headers}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        all_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(base + path, data=data, method=method, headers=all_headers)
    try:
        with OPENER.open(request, timeout=HTTP_TIMEOUT_SEC) as response:
            status, payload = response.status, response.read()
    except urllib.error.HTTPError as err:
        with err:
            code = error_code(err.read())
        raise ApiError("%s: HTTP %d%s" % (name, err.code, " " + code if code else ""), err.code, code)
    except (urllib.error.URLError, OSError, http.client.HTTPException) as err:
        raise ApiError("%s: %s" % (name, getattr(err, "reason", err)))
    if status not in expect:
        raise ApiError("%s: unexpected HTTP %d" % (name, status), status)
    if not payload:
        return None
    try:
        return json.loads(payload)
    except vekrona_vpn.JSON_ERRORS:
        raise ApiError("%s: the answer is not JSON" % name, status)
