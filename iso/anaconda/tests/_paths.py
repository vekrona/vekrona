import sys
from pathlib import Path

ADDONS_DIR = Path(__file__).resolve().parent.parent / "updates/usr/share/anaconda/addons"
sys.path.insert(0, str(ADDONS_DIR))
