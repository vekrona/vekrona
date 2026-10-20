import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parents[3] / "tests"
sys.path.insert(0, str(TESTS_DIR))
from require_vm import require_vm  # noqa: E402

require_vm()

ADDONS_DIR = Path(__file__).resolve().parent.parent / "updates/usr/share/anaconda/addons"
sys.path.insert(0, str(ADDONS_DIR))
