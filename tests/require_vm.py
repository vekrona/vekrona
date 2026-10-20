import os
import subprocess
import sys

GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "require-vm.sh")


def require_vm():
    """Exits unless tests/require-vm.sh allows a test here: the vekrona-dev guest, or GitHub Actions' container."""
    result = subprocess.run(["bash", GUARD], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(result.stderr.strip())
