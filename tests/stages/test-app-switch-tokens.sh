#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"

# The app switcher reads config/tokens.json by name at runtime and silently falls back to a monochrome set when a
# name is missing. This holds every name it looks up to the tokens the design defines, so a renamed token fails here.
# Convention: shell.qml looks tokens up only as token("name") and type styles only as typeStyle("name"), and lists
# a fallback for each token("name") as a quoted-key line of the `fallbacks` object.
QML="$ROOT/config/vekrona-app-switch/shell.qml"
TOKENS="$ROOT/config/vekrona-app-switch/tokens.json"

[[ -r "$TOKENS" ]] || die "$TOKENS does not resolve to a readable file"

python3 - "$QML" "$TOKENS" <<'PY'
import json, re, sys

qml = open(sys.argv[1]).read()
design = json.load(open(sys.argv[2]))

looked_up = set(re.findall(r'\btoken\("([^"]+)"\)', qml))
styles = set(re.findall(r'\btypeStyle\("([^"]+)"\)', qml))
fallbacks = set(re.findall(r'^\s+"([a-z0-9-]+)":', qml, re.M))
assert looked_up and styles, "no token lookups found; the grep convention broke"

defined = {t["name"] for group in ("color", "spacing", "border", "size") for t in design[group]["tokens"]}
styles_defined = {s["name"] for g in design["type"]["groups"] for s in g["styles"]}

problems = []
problems += [f"token {n!r} is not in tokens.json" for n in sorted(looked_up - defined)]
problems += [f"type style {n!r} is not in tokens.json" for n in sorted(styles - styles_defined)]
problems += [f"token {n!r} has no fallback" for n in sorted(looked_up - fallbacks)]
problems += [f"fallback {n!r} is never looked up" for n in sorted(fallbacks - looked_up)]
if problems:
    sys.exit("\n".join(problems))
print(f"ok: {len(looked_up)} tokens and {len(styles)} type style(s) all exist in tokens.json")
PY
