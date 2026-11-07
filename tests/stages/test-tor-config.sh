#!/usr/bin/env bash
# The files that tor, systemd and sysusers read cannot source lib/tor.sh, so they spell its group, directory and socket by hand.
# Each spelling must agree with the library, or the socket tor makes lands where nobody looks for it.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"
# shellcheck source=../../lib/tor.sh
source "$REPO/lib/tor.sh"

has_line() { grep -qxF -- "$2" "$REPO/$1" || die "$1 must have the line '$2', which spells lib/tor.sh"; }

has_line etc/tor/torrc.d/vekrona.conf "SocksPort unix:$VEKRONA_TOR_SOCKET GroupWritable"
has_line etc/systemd/system/tor.service.d/vekrona.conf "ReadWritePaths=-$VEKRONA_TOR_SOCKET_DIR"
has_line etc/sysusers.d/vekrona-tor.conf "g $VEKRONA_TOR_GROUP -"
log "ok: torrc, the tor.service drop-in and the sysusers entry name the group, directory and socket of lib/tor.sh"
