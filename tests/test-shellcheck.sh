#!/usr/bin/env bash
# Every shell file of the repo passes shellcheck with no finding at any severity. The file set is every file whose first line is a
# bash or sh shebang, plus every *.sh (the sourced libraries carry no shebang, only `# shellcheck shell=bash`), so a new tool is
# covered without listing it here. The directories below hold downloads, build output and Git's own files, not the repo's code.
set -euo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
cd "$REPO"

command -v shellcheck >/dev/null || {
  echo "shellcheck is not installed (dnf install ShellCheck)" >&2
  exit 1
}

mapfile -t files < <(
  {
    find . \( -path ./.git -o -path ./.claude -o -path ./iso/.cache -o -path ./iso/out -o -path ./iso/downloads \) -prune -o \
      -type f -exec awk 'FNR == 1 { if ($0 ~ /^#!.*(bash|\/sh)([ \t]|$)/) print FILENAME; nextfile }' {} +
    find . \( -path ./.git -o -path ./.claude -o -path ./iso/.cache -o -path ./iso/out -o -path ./iso/downloads \) -prune -o \
      -type f -name '*.sh' -print
  } | sort -u
)
[[ ${#files[@]} -gt 0 ]] || {
  echo "found no shell files; the file set lookup is broken" >&2
  exit 1
}

echo "shellcheck over ${#files[@]} files"
shellcheck "${files[@]}"
