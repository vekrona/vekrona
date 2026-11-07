#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"
# shellcheck source=../../lib/vpn.sh
source "$REPO/lib/vpn.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/installed"
UNIT="$work/installed/$VEKRONA_RETIRED_KILLSWITCH_UNIT"

cat > "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
cat > "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
case "$1" in
  is-active) echo inactive; exit 3 ;;
  is-failed) echo inactive; exit 4 ;;
esac
F
# nft records what it was given, and whether the unit file was still there when it was asked.
cat > "$work/bin/nft" <<'F'
#!/usr/bin/env bash
echo "nft $*" >> "$STUB_LOG"
if [[ -e "$STUB_UNIT" ]]; then echo "the unit file was there" >> "$STUB_LOG"; fi
cat >> "$STUB_NFT_INPUT"
F
chmod +x "$work/bin"/*
export PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_NFT_INPUT="$work/nft-input" STUB_UNIT="$UNIT" VEKRONA_SYSTEMD_UNIT_DIR="$work/installed"

: > "$STUB_LOG"
: > "$STUB_NFT_INPUT"
retire_vpn_killswitch_unit 2>/dev/null
[[ ! -s "$STUB_LOG" ]] || die "a machine without the retired unit file was given an nft command: $(cat "$STUB_LOG")"
log "ok: without the retired unit file the nft table, which is the current design's, is left alone"

printf '[Unit]\nDescription=old kill switch\n' > "$UNIT"
retire_vpn_killswitch_unit 2>/dev/null
grep -qx 'nft -f -' "$STUB_LOG" || die "the table of the retired unit was not deleted: $(cat "$STUB_LOG")"
[[ "$(cat "$STUB_NFT_INPUT")" == $'table inet vekrona-vpn\ndelete table inet vekrona-vpn' ]] \
  || die "nft was not told to declare and delete the table: $(cat "$STUB_NFT_INPUT")"
grep -qx 'the unit file was there' "$STUB_LOG" || die "the unit file was removed before the table was deleted, so a run that stops in between keeps the table"
[[ ! -e "$UNIT" ]] || die "the retired unit file was kept"
log "ok: the table of the retired unit is deleted, then the unit file"

: > "$STUB_LOG"
retire_vpn_killswitch_unit 2>/dev/null
[[ ! -s "$STUB_LOG" ]] || die "a second run touched nft again: $(cat "$STUB_LOG")"
log "ok: a second run changes nothing"
