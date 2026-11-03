import os
import tempfile
from pathlib import Path

from vekrona_signin.core.errors import SignInError

__all__ = ["U2F_MAPPINGS_RELATIVE_PATH", "merge_u2f_mappings", "write_u2f_mappings"]

# The one registration file every pam_u2f line reads (lib/pam-u2f.sh): root's, so no process of the user can register a key.
U2F_MAPPINGS_RELATIVE_PATH = Path("etc/u2f_mappings")
# The lock screen runs pam_u2f as the user, so the file must be readable by everyone.
MAPPINGS_MODE = 0o644


def merge_u2f_mappings(existing, username, line):
    """The file text after registering `line` for `username`: one line per entry, each ending in a newline, as
    ensure_u2f_mappings in lib/pam-u2f.sh writes it. Other users' lines stay; an older line of the user is replaced."""
    prefix = f"{username}:"
    if not line.startswith(prefix) or "\n" in line or "\r" in line:
        raise SignInError(f"The registration is not one line for {username}; refusing to write it into {U2F_MAPPINGS_RELATIVE_PATH}.")
    kept = [entry for entry in existing.split("\n") if entry and not entry.startswith(prefix)]
    return "".join(f"{entry}\n" for entry in [*kept, line])


def write_u2f_mappings(sysroot, username, line, uid, gid):
    """Register `line` in `sysroot`/etc/u2f_mappings, owned by uid:gid with mode 0644. The new text goes into a temporary file
    in the same directory and is renamed over the file, so the file is never half written."""
    path = Path(sysroot) / U2F_MAPPINGS_RELATIVE_PATH
    existing = path.read_text() if path.exists() else ""
    content = merge_u2f_mappings(existing, username, line)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w") as mappings:
            os.fchown(descriptor, uid, gid)
            os.fchmod(descriptor, MAPPINGS_MODE)
            mappings.write(content)
            mappings.flush()
            os.fsync(descriptor)
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
