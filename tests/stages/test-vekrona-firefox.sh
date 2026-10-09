#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# bin/vekrona-firefox reads the main Firefox profile: bookmarks and history from places.sqlite, the default
# search engine from search.json.mozlz4. The profile is a fixture built here.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

export HOME="$scratch/home"
unset XDG_CONFIG_HOME
tool="$ROOT/bin/vekrona-firefox"
ff_root="$HOME/.config/mozilla/firefox"
main="$ff_root/abc.default-release"
webapp="$ff_root/vekrona-youtube"

FIXTURE_PY="$(cat <<'PY'
import json
import os
import sqlite3
import sys


def length_bytes(n):  # the LZ4 extension bytes of a length that overflowed its 4-bit field
    out = bytearray()
    while n >= 255:
        out.append(255)
        n -= 255
    out.append(n)
    return bytes(out)


def sequence(literals, offset=None, match=None):
    token = min(len(literals), 15) << 4 | (min(match - 4, 15) if match else 0)
    out = bytearray([token])
    if len(literals) >= 15:
        out += length_bytes(len(literals) - 15)
    out += literals
    if match:
        out += offset.to_bytes(2, "little")
        if match - 4 >= 15:
            out += length_bytes(match - 4 - 15)
    return bytes(out)


def write_mozlz4(path, block, size):
    with open(path, "wb") as f:
        f.write(b"mozLz40\0" + size.to_bytes(4, "little") + block)


def write_engines(path, default_id, app_default_id):
    # The padding is a run of one byte, which a real compressor stores as a match overlapping its own output.
    head = json.dumps({
        "version": 6,
        "engines": [
            {"id": "ddg", "_name": "DuckDuckGo", "_isConfigEngine": True},
            {"id": "u-1", "_name": "Example Search", "_loadPath": "[user]",
             "_urls": [{"template": "https://search.example/?q={searchTerms}"}]},
        ],
        "metaData": {"appDefaultEngineId": app_default_id, "defaultEngineId": default_id},
        "pad": "a" * 300,
    })
    start = head.index("a" * 300)
    before, tail = head[:start + 1].encode(), head[start + 300:].encode()
    block = sequence(before, offset=1, match=299) + sequence(tail)
    write_mozlz4(path, block, len(before) + 299 + len(tail))


def write_places(path, rows, bookmarks):
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER,"
               " hidden INTEGER, frecency INTEGER)")
    db.execute("CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, title TEXT)")
    db.executemany("INSERT INTO moz_places VALUES (?, ?, ?, ?, ?, ?)", rows)
    db.executemany("INSERT INTO moz_bookmarks (type, fk, title) VALUES (?, ?, ?)", bookmarks)
    db.commit()
    db.close()


def main_places(path):
    write_places(path, [
        (1, "https://example.org/docs", "Example Docs", 5, 0, 2000),
        (2, "https://example.org/blog", "Example Blog", 3, 0, 1000),
        (3, "https://primer.test/", "Другой Пример", 1, 0, 100),
        (4, "place:type=6&sort=14", "Recent Tags", 0, 0, 0),
        (5, "https://hidden.example/", "Hidden Page", 1, 1, 900),
        (6, "https://unvisited.example/", "Unvisited Page", 0, 0, 500),
        (7, "https://nowhere.test/never", None, 0, 0, -1),
        (8, "https://example.org/about", "Example About", 2, 0, 300),
        (9, "ftp://example.org/files", "Example Files", 1, 0, 700),
        (10, "https://de.test/s", "Straße", 1, 0, 1000),
    ], [
        (1, 1, "Docs Bookmark"),
        (1, 1, "Docs Bookmark Twice"),
        (1, 4, "Recent Tags"),
        (2, None, "A Folder"),
        (1, 7, ""),
    ])


command = sys.argv[1]
if command == "main-places":
    main_places(sys.argv[2])
elif command == "webapp-places":
    write_places(sys.argv[2], [(1, "https://webapp-only.example/", "Webapp Only", 1, 0, 100)], [])
elif command == "engines":
    write_engines(*sys.argv[2:5])
elif command == "raw-mozlz4":
    write_mozlz4(sys.argv[2], os.fsencode(sys.argv[3]), int(sys.argv[4]))
elif command == "hold-lock":
    db = sqlite3.connect(sys.argv[2], isolation_level=None)
    db.execute("BEGIN EXCLUSIVE")
    print("locked", flush=True)
    sys.stdin.read()
else:
    sys.exit(f"unknown fixture command {command}")
PY
)"
fixture() { python3 -B -c "$FIXTURE_PY" "$@"; }

reset_profile() {
  rm -rf "$HOME"
  mkdir -p "$main" "$webapp"
  cat > "$ff_root/profiles.ini" <<INI
[Profile1]
Name=vekrona-youtube
IsRelative=1
Path=vekrona-youtube
Default=1

[Profile0]
Name=default-release
IsRelative=1
Path=abc.default-release

[Install4F96D1932A9F858E]
Default=abc.default-release
Locked=1
INI
  fixture main-places "$main/places.sqlite"
  fixture webapp-places "$webapp/places.sqlite"
  fixture engines "$main/search.json.mozlz4" u-1 ddg
}

run_tool() { "$tool" "$@" >"$scratch/stdout" 2>"$scratch/stderr"; }
ok_run() { run_tool "$@" || die "$*: $(cat "$scratch/stderr")"; }
fails() { # fails <why> <stderr-substring> <tool args...>
  local why="$1" needle="$2"; shift 2
  if run_tool "$@"; then die "$why: must fail"; fi
  grep -qF -- "$needle" "$scratch/stderr" || die "$why: error does not say '$needle': $(cat "$scratch/stderr")"
  [[ ! -s "$scratch/stdout" ]] || die "$why: printed to stdout despite failing: $(cat "$scratch/stdout")"
}
succeeds_empty() { # succeeds_empty <why> <tool args...>: a fresh Firefox is not a failure, it has nothing to list
  local why="$1"; shift
  run_tool "$@" || die "$why: must succeed, failed with: $(cat "$scratch/stderr")"
  [[ ! -s "$scratch/stdout" && ! -s "$scratch/stderr" ]] || die "$why: must print nothing: $(cat "$scratch/stdout" "$scratch/stderr")"
}
# rows <query> [--limit N]: the output as "kind title score" lines
rows() { ok_run places "$@"; jq -r '[.kind, .title, .score] | join(" | ")' "$scratch/stdout"; }
expect_rows() { # expect_rows <why> <expected, newline separated> <places args...>
  local why="$1" expected="$2"; shift 2
  [[ "$(rows "$@")" == "$expected" ]] || die "$why: got: $(rows "$@")"
}

reset_profile

# ---------------------------------------------------------------- places

expect_rows "bookmarks come first, by frecency, each page once, a bookmark not repeated as history" \
"bookmark | Docs Bookmark | 1.0
history | Example Blog | 0.4737
history | Example About | 0.1053" example
expect_rows "case folding is Unicode full folding, ß is ss" "history | Straße | 0.4737" "STRASSE"
expect_rows "words match in any order and in any letter case" "bookmark | Docs Bookmark | 1.0" "DOCS exAMPLE"
expect_rows "the URL matches" "history | Example Blog | 0.4737" ORG/BLOG
expect_rows "non-ASCII letters fold their case" "history | Другой Пример | 0.0" "ПРИМЕР"
expect_rows "an unvisited bookmark scores 0 and has no title to show but its URL" \
  "bookmark | https://nowhere.test/never | 0.0" never
expect_rows "the limit counts per kind" "bookmark | Docs Bookmark | 1.0
history | Example Blog | 0.4737" example --limit 1
expect_rows "a query that matches nothing prints nothing" "" no-such-page
for hidden in "Hidden Page" "unvisited" "Recent Tags" "files" "webapp-only"; do
  expect_rows "$hidden is not a result (hidden, unvisited, place: URL, non-web URL, other profile)" "" "$hidden"
done
cp "$webapp/places.sqlite" "$main/places.sqlite"
expect_rows "a lone page is as frecent as the most frecent one" "history | Webapp Only | 1.0" webapp
rm "$main/places.sqlite"
fixture main-places "$main/places.sqlite"

ok_run places example
[[ "$(jq -r .url "$scratch/stdout" | tr '\n' ' ')" == "https://example.org/docs https://example.org/blog https://example.org/about " ]] \
  || die "the rows carry the wrong URLs: $(<"$scratch/stdout")"

coproc LOCK { fixture hold-lock "$main/places.sqlite"; }
read -r -u "${LOCK[0]}" lock_state && [[ "$lock_state" == locked ]] || die "the lock holder did not take the lock"
expect_rows "places can be read while another process holds the database exclusively" \
"bookmark | Docs Bookmark | 1.0
history | Example Blog | 0.4737
history | Example About | 0.1053" example
exec {LOCK[1]}>&-
wait "$LOCK_PID"

fails "--limit 0" "not a positive integer" places example --limit 0
fails "--limit lizard" "not a positive integer" places example --limit lizard
rm "$main/places.sqlite"
succeeds_empty "Firefox has not created places.sqlite yet" places example
printf 'not a database, long enough to be read as a page header and fail the check........' > "$main/places.sqlite"
fails "corrupt places.sqlite" "places.sqlite query failed" places example

# ---------------------------------------------------------------- engine-name

reset_profile
ok_run engine-name
[[ "$(<"$scratch/stdout")" == "Example Search" ]] || die "the user's default engine is not named: $(<"$scratch/stdout")"

fixture engines "$main/search.json.mozlz4" "" ddg
ok_run engine-name
[[ "$(<"$scratch/stdout")" == "DuckDuckGo" ]] || die "an unset default does not fall back to the app default: $(<"$scratch/stdout")"

fixture engines "$main/search.json.mozlz4" "" ""
fails "no engine chosen and no app default" "names no default engine" engine-name

fixture engines "$main/search.json.mozlz4" gone ddg
fails "default engine absent from the engine list" "default engine gone is not among its engines" engine-name

rm "$main/search.json.mozlz4"
succeeds_empty "Firefox has not created search.json.mozlz4 yet" engine-name

printf 'plain json, not mozlz4' > "$main/search.json.mozlz4"
fails "wrong magic" "is not a mozLz4 file" engine-name

fixture raw-mozlz4 "$main/search.json.mozlz4" $'\x40'"{}}}" 99
fails "block shorter than its header says" "decoded to" engine-name

fixture raw-mozlz4 "$main/search.json.mozlz4" $'\xf0\x20' 20
fails "block cut in the middle of a literal run" "truncated" engine-name

fixture raw-mozlz4 "$main/search.json.mozlz4" $'\x10a\x05\x01' 20
fails "match reaching before the start" "points before the start" engine-name

fixture raw-mozlz4 "$main/search.json.mozlz4" $'\x30not' 3
fails "bytes that are no JSON" "could not decode" engine-name

# ---------------------------------------------------------------- profiles

reset_profile
rm -r "$main"
fails "profile directory gone" "profile directory does not exist" engine-name
fails "profile directory gone for places" "profile directory does not exist" places example

rm "$ff_root/profiles.ini"
succeeds_empty "no profiles.ini, Firefox never started: engine-name" engine-name
succeeds_empty "no profiles.ini, Firefox never started: places" places example

printf '[General]\nVersion=2\n' > "$ff_root/profiles.ini"
succeeds_empty "profiles.ini without a default: engine-name" engine-name
succeeds_empty "profiles.ini without a default: places" places example

printf '[Install1]\nDefault=a\n\n[Install2]\nDefault=b\n' > "$ff_root/profiles.ini"
fails "two install sections" "cannot tell the default profile" engine-name

ok_run profile-root
[[ "$(<"$scratch/stdout")" == "$ff_root" ]] || die "profile-root is not the XDG location: $(<"$scratch/stdout")"
mkdir -p "$HOME/.mozilla/firefox"
ok_run profile-root
[[ "$(<"$scratch/stdout")" == "$HOME/.mozilla/firefox" ]] || die "profile-root ignores the legacy location: $(<"$scratch/stdout")"
XDG_CONFIG_HOME="$scratch/xdg" ok_run profile-root
[[ "$(<"$scratch/stdout")" == "$HOME/.mozilla/firefox" ]] || die "the legacy location must win over XDG_CONFIG_HOME"
rmdir "$HOME/.mozilla/firefox"
XDG_CONFIG_HOME="$scratch/xdg" ok_run profile-root
[[ "$(<"$scratch/stdout")" == "$scratch/xdg/mozilla/firefox" ]] || die "profile-root ignores XDG_CONFIG_HOME: $(<"$scratch/stdout")"

log "vekrona-firefox: all scenarios passed"
