#!/usr/bin/env bash
# Bakes config/vekrona-shell/*.frag into the committed .qsb files with the guest's Qt shader baker, so the host needs no Qt.
# Without arguments it rewrites the .qsb files; with --check it fails when one differs from a fresh bake.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/lib.sh"

SHELL_DIR="$ROOT/config/vekrona-shell"
GUEST_SHELL_DIR=/mnt/vekrona/config/vekrona-shell
QSB=/usr/lib64/qt6/bin/qsb
QSB_PKG=qt6-qtshadertools
# Qt's --qt6 set minus "100 es", which has no texelFetch or textureSize, plus "300 es" for GLES 3.
QSB_TARGETS=(--glsl "120,150,300 es" --hlsl 50 --msl 12)

mode="${1:-bake}"
[[ $# -le 1 && ( "$mode" == bake || "$mode" == --check ) ]] || die "usage: $0 [--check]"

vekrona-dev run bash -c 'rpm -q "$1" >/dev/null || sudo dnf install -y "$1" >&2' _ "$QSB_PKG"
fresh="$(mktemp -d)"
trap 'rm -rf "$fresh"' EXIT
for frag in "$SHELL_DIR"/*.frag; do
  name="$(basename "$frag")"
  # The guest mount is read-only, so the baker writes to stdout.
  vekrona-dev run "$QSB" "${QSB_TARGETS[@]}" -o /dev/stdout "$GUEST_SHELL_DIR/$name" >"$fresh/$name.qsb"
  if [[ "$mode" == bake ]]; then
    cp "$fresh/$name.qsb" "$SHELL_DIR/$name.qsb"
  else
    cmp -s "$fresh/$name.qsb" "$SHELL_DIR/$name.qsb" || die "$name.qsb is stale; run tests/bake-shaders.sh"
  fi
done
