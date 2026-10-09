"""Firefox profile discovery and reading, shared by bin/vekrona-render-theme and bin/vekrona-firefox."""
import configparser
import json
import os

import vekrona_cli

MOZLZ4_MAGIC = b"mozLz40\0"


class FirefoxError(Exception):
    pass


# ---------------------------------------------------------------- profiles

def firefox_profile_root():
    legacy = os.path.join(os.path.expanduser("~"), ".mozilla", "firefox")
    if os.path.isdir(legacy):
        return legacy
    return os.path.join(vekrona_cli.xdg_config_home(), "mozilla", "firefox")


def read_profiles_ini():
    """Returns (root, parser), or None when Firefox has no profiles yet."""
    root = firefox_profile_root()
    ini = os.path.join(root, "profiles.ini")
    if not os.path.isfile(ini):
        return None
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(ini)
    except (OSError, configparser.Error) as e:
        raise FirefoxError(f"could not read {ini}: {e}")
    return root, parser


def profile_dir(root, parser, section):
    path = parser[section].get("Default" if section.startswith("Install") else "Path")
    if not path:
        return None
    relative = parser[section].get("IsRelative", "1") == "1" or section.startswith("Install")
    return os.path.join(root, path) if relative and not os.path.isabs(path) else path


def find_default_profile(root, parser):
    installs = [s for s in parser.sections() if s.startswith("Install") and parser[s].get("Default")]
    if len(installs) > 1:
        raise FirefoxError(f"{os.path.join(root, 'profiles.ini')} has several [Install*] sections, "
                           f"cannot tell the default profile: {', '.join(installs)}")
    if installs:
        return profile_dir(root, parser, installs[0])
    for section in parser.sections():
        if not section.startswith("Profile") or parser[section].get("Default") != "1":
            continue
        if parser[section].get("Name", "").startswith("vekrona-"):
            continue
        return profile_dir(root, parser, section)
    return None


def find_webapp_profiles(root, parser):
    dirs = [profile_dir(root, parser, s) for s in parser.sections()
            if s.startswith("Profile") and parser[s].get("Name", "").startswith("vekrona-")]
    return [d for d in dirs if d]


def default_profile():
    """The main profile directory, or None when Firefox has no profile yet (no profiles.ini, or no default in
    it: Firefox writes both on its first start). FirefoxError when profiles.ini is ambiguous or unreadable, or
    names a directory that is gone."""
    profiles = read_profiles_ini()
    if profiles is None:
        return None
    profile = find_default_profile(*profiles)
    if profile is None:
        return None
    if not os.path.isdir(profile):
        raise FirefoxError(f"Firefox profile directory does not exist: {profile}")
    return profile


# ---------------------------------------------------------------- mozLz4

def lz4_block_decompress(data, size):
    """Decodes one LZ4 block (no frame header) that expands to exactly `size` bytes."""
    out = bytearray()
    i = 0

    def length(base):
        nonlocal i
        if base == 15:
            while True:
                extra = data[i]
                i += 1
                base += extra
                if extra != 255:
                    break
        return base

    try:
        while i < len(data):
            token = data[i]
            i += 1
            literals = length(token >> 4)
            if i + literals > len(data):
                raise FirefoxError("LZ4 block is truncated")
            out += data[i:i + literals]
            i += literals
            if i >= len(data):
                break
            offset = data[i] | data[i + 1] << 8
            i += 2
            match = length(token & 15) + 4
            if offset == 0 or offset > len(out):
                raise FirefoxError(f"LZ4 match offset {offset} points before the start of the data")
            start = len(out) - offset
            for k in range(match):  # byte by byte: a match may overlap the bytes it produces
                out.append(out[start + k])
    except IndexError:
        raise FirefoxError("LZ4 block is truncated")
    if len(out) != size:
        raise FirefoxError(f"LZ4 block decoded to {len(out)} bytes, its header says {size}")
    return bytes(out)


def read_mozlz4_json(path):
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        raise FirefoxError(f"could not read {path}: {e}")
    if not raw.startswith(MOZLZ4_MAGIC) or len(raw) < len(MOZLZ4_MAGIC) + 4:
        raise FirefoxError(f"{path} is not a mozLz4 file")
    header = len(MOZLZ4_MAGIC)
    size = int.from_bytes(raw[header:header + 4], "little")
    try:
        return json.loads(lz4_block_decompress(raw[header + 4:], size))
    except (FirefoxError, UnicodeDecodeError, json.JSONDecodeError) as e:
        raise FirefoxError(f"could not decode {path}: {e}")
