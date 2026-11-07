import argparse
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile


def sibling_bin(script_file, name):
    candidate = os.path.join(os.path.dirname(os.path.realpath(script_file)), name)
    return candidate if os.path.isfile(candidate) else None


def resolve_tool(script_file, name):
    return sibling_bin(script_file, name) or shutil.which(name)


def repo_root(script_file):
    return os.path.dirname(os.path.dirname(os.path.realpath(script_file)))


def xdg_dir(env_var, fallback_parts):
    return os.environ.get(env_var) or os.path.join(os.path.expanduser("~"), *fallback_parts)


def xdg_state_home():
    return xdg_dir("XDG_STATE_HOME", (".local", "state"))


def xdg_config_home():
    return xdg_dir("XDG_CONFIG_HOME", (".config",))


def xdg_data_home():
    return xdg_dir("XDG_DATA_HOME", (".local", "share"))


def vekrona_state_dir():
    return os.path.join(xdg_state_home(), "vekrona")


def vekrona_config_dir():
    return os.path.join(xdg_config_home(), "vekrona")


def write_atomically(path, text, *, mode=0o600, directory_mode=0o777):
    """Replaces path with text through a temp file and a rename, so a reader never sees half a file. The file is born with mode
    and its directory, when missing, is made with directory_mode (before the umask)."""
    directory, name = os.path.split(path)
    os.makedirs(directory, mode=directory_mode, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(dir=directory, prefix=f".{name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            os.fchmod(f.fileno(), mode)
            f.write(text)
        os.replace(temp_path, path)
    except BaseException:
        os.unlink(temp_path)
        raise


def write_json_atomically(path, data):
    """Replaces path with data as JSON (see write_atomically)."""
    write_atomically(path, json.dumps(data) + "\n")


def run_quietly(argv):
    try:
        result = subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"{argv[0]}: {exc}"
    if result.returncode != 0:
        detail = (result.stderr or "").strip()
        return f"{argv[0]} exited with status {result.returncode}" + (f": {detail}" if detail else "")
    return None


def notify_send(prog, msg, urgency="critical"):
    return run_quietly(["notify-send", "-u", urgency, "-a", "vekrona", "--", prog, msg])


def report_to_vekrona_error(prog, msg, script_file):
    bin_path = resolve_tool(script_file, "vekrona-error")
    if not bin_path:
        return "vekrona-error not found"
    return run_quietly([bin_path, "report", "--title", f"{prog}: {msg}", "--source", "vekrona"])


def surface_failure(prog, msg, script_file, report=True):
    """One failure, one record and no notification: the robot's dot and list show the record. A plain critical toast is
    the last resort, sent only when the failure could not be recorded, or for the tool that is the recorder itself."""
    if report:
        report_failure = report_to_vekrona_error(prog, msg, script_file)
        if report_failure is None:
            return
        print(f"{prog}: WARN: failed to report this error to vekrona-error: {report_failure}", file=sys.stderr)
    notify_failure = notify_send(prog, msg)
    if notify_failure:
        print(f"{prog}: WARN: failed to show this error as a notification: {notify_failure}", file=sys.stderr)


def print_failure(prog, msg):
    print(f"{prog}: {msg}", file=sys.stderr)


def exit_unrecorded(prog, msg):
    """Ends the command with the failure on stderr only, for a tool whose caller records the failure or toasts it."""
    print_failure(prog, msg)
    sys.exit(1)


def require_run_verb(prog, description):
    """Refuses a bare call, with the usage and exit status 2: a tool that acts when it starts is started as `<prog> run`."""
    parser = argparse.ArgumentParser(prog=prog, description=description)
    parser.add_subparsers(dest="command", required=True).add_parser("run", help="do what the tool is for")
    parser.parse_args()


def make_die(prog, script_file, report=True):
    def die(msg):
        print_failure(prog, msg)
        surface_failure(prog, msg, script_file, report)
        sys.exit(1)
    return die


PORTAL_NAME = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
PORTAL_CALL_TIMEOUT_MS = 10000
PORTAL_RESPONSE_OK = 0
PORTAL_RESPONSE_CANCELLED = 1


class PortalError(Exception):
    """The file chooser could not be used (python3-gobject or the portal is missing, or the portal broke off)."""


def choose_paths(title, directory):
    """What the user picks in the portal's file chooser: one directory, or any number of files. [] when it is cancelled."""
    try:
        import gi
        gi.require_version("Gio", "2.0")
        gi.require_version("GLib", "2.0")
        from gi.repository import Gio, GLib
    except (ImportError, ValueError) as exc:
        raise PortalError(f"the file chooser needs python3-gobject: {exc}")
    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    token = f"vekrona_{secrets.token_hex(4)}"
    # The portal answers on a request path it derives from our bus name and token, which is known before the call.
    request_path = (f"/org/freedesktop/portal/desktop/request/"
                    f"{bus.get_unique_name().lstrip(':').replace('.', '_')}/{token}")
    loop = GLib.MainLoop()
    outcome = {}

    def on_response(connection, sender, path, interface, signal, params, user_data):
        outcome["code"], results = params.unpack()
        outcome["uris"] = results.get("uris", [])
        loop.quit()

    def on_name_owner_changed(connection, sender, path, interface, signal, params, user_data):
        if not params.unpack()[2]:
            outcome["error"] = "the desktop portal went away while the file chooser was open"
            loop.quit()

    bus.signal_subscribe(PORTAL_NAME, "org.freedesktop.portal.Request", "Response", request_path, None,
                         Gio.DBusSignalFlags.NONE, on_response, None)
    bus.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus",
                         PORTAL_NAME, Gio.DBusSignalFlags.NONE, on_name_owner_changed, None)
    options = {"handle_token": GLib.Variant("s", token), "directory": GLib.Variant("b", directory),
               "multiple": GLib.Variant("b", not directory)}
    try:
        bus.call_sync(PORTAL_NAME, PORTAL_PATH, "org.freedesktop.portal.FileChooser", "OpenFile",
                      GLib.Variant("(ssa{sv})", ("", title, options)), GLib.VariantType("(o)"),
                      Gio.DBusCallFlags.NONE, PORTAL_CALL_TIMEOUT_MS, None)
    except GLib.Error as exc:
        raise PortalError(f"cannot open the file chooser: {exc.message}")
    loop.run()
    if "error" in outcome:
        raise PortalError(outcome["error"])
    if outcome["code"] == PORTAL_RESPONSE_CANCELLED:
        return []
    if outcome["code"] != PORTAL_RESPONSE_OK:
        raise PortalError(f"the file chooser ended with the portal's response {outcome['code']}")
    paths = [Gio.File.new_for_uri(uri).get_path() for uri in outcome["uris"]]
    if None in paths:
        raise PortalError(f"the file chooser returned something that is not a local path: {outcome['uris']}")
    return paths
