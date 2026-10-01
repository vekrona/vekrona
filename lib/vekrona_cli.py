import html
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
    return run_quietly(["notify-send", "-u", urgency, "-a", "vekrona", "--", prog, html.escape(msg, quote=False)])


def report_to_vekrona_error(prog, msg, script_file):
    bin_path = resolve_tool(script_file, "vekrona-error")
    if not bin_path:
        return "vekrona-error not found"
    return run_quietly([bin_path, "report", "--title", f"{prog}: {msg}", "--source", "vekrona"])


def make_die(prog, script_file, report=True):
    def die(msg):
        print(f"{prog}: {msg}", file=sys.stderr)
        notify_failure = notify_send(prog, msg)
        if notify_failure:
            print(f"{prog}: WARN: failed to show this error as a notification: {notify_failure}", file=sys.stderr)
        if report:
            report_failure = report_to_vekrona_error(prog, msg, script_file)
            if report_failure:
                print(f"{prog}: WARN: failed to report this error to vekrona-error: {report_failure}",
                      file=sys.stderr)
        sys.exit(1)
    return die
