import os
import subprocess


def report_error(prog, message, source="vekrona"):
    bin_path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "vekrona-error")
    if not os.path.isfile(bin_path):
        return False
    try:
        result = subprocess.run(
            [bin_path, "report", "--title", f"{prog}: {message}", "--source", source],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5,
        )
        return result.returncode == 0
    except Exception:
        return False
