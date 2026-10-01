import os
from pathlib import Path

__all__ = ["write_private_file"]

PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600


def write_private_file(base, path, content, uid, gid):
    directory = Path(base)
    for part in Path(path).parent.relative_to(base).parts:
        directory = directory / part
        if not directory.is_dir():
            directory.mkdir(mode=PRIVATE_DIRECTORY_MODE)
            os.chown(directory, uid, gid)
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, PRIVATE_FILE_MODE
    )
    with os.fdopen(descriptor, "wb") as private_file:
        os.fchown(descriptor, uid, gid)
        os.fchmod(descriptor, PRIVATE_FILE_MODE)
        private_file.write(content)
