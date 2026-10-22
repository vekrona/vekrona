import argparse
import os
import shutil
import subprocess
import sys


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


def vekrona_state_dir():
    return os.path.join(xdg_state_home(), "vekrona")


def vekrona_config_dir():
    return os.path.join(xdg_config_home(), "vekrona")


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
