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


def notify_send(prog, msg, urgency="critical"):
    try:
        subprocess.run(
            ["notify-send", "-u", urgency, "-a", "vekrona", prog, msg],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        )
    except Exception:
        pass


def report_to_vekrona_error(prog, msg, script_file):
    bin_path = resolve_tool(script_file, "vekrona-error")
    if not bin_path:
        return False
    try:
        result = subprocess.run(
            [bin_path, "report", "--title", f"{prog}: {msg}", "--source", "vekrona"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return False


def make_die(prog, script_file, report=True):
    def die(msg):
        print(f"{prog}: {msg}", file=sys.stderr)
        notify_send(prog, msg)
        if report and not report_to_vekrona_error(prog, msg, script_file):
            print(f"{prog}: WARN: failed to report this error to vekrona-error", file=sys.stderr)
        sys.exit(1)
    return die
