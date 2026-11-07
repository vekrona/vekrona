#!/usr/bin/env bash
# libexec/vekrona-tor-route owns the rules of the shape `uidrange N-N lookup main` at priority 100, whatever N is, and no other: `down`
# deletes them (duplicates and the rule of a recreated user included), `up` leaves one for the tor user, an `ip` that fails to list is
# an error, not an empty list, and an `up` that fails leaves none behind. Stands in for root with `unshare -r`, for `ip` with a stub
# that keeps its rules in files and for `id` with one that knows the tor user.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"

require_user_namespaces

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export FAKE_IP_DIR="$work/ip"
mkdir -p "$FAKE_IP_DIR"
TOR_UID=970   # the uid of the tor user now,
STALE_UID=971 # and the uid it had before it was recreated

# Rules of the family $1 in $FAKE_IP_DIR/rules$1, one per line, as `ip -o rule show` prints them. FAKE_IP_BROKEN names a file whose
# presence makes every listing fail; FAKE_IP_BREAK_ON_DEL makes the first delete create it; FAKE_IP_FAIL_ADD_FAMILY makes the add of
# that family (-4 or -6) fail.
cat > "$work/bin/ip" <<'F'
#!/usr/bin/env bash
family="$1"
rules="$FAKE_IP_DIR/rules$family"
echo "$*" >> "$FAKE_IP_DIR/calls"
case "$*" in
  *"rule show"*)
    if [[ -e "$FAKE_IP_DIR/broken" ]]; then echo "RTNETLINK answers: boom" >&2; exit 2; fi
    cat "$rules" ;;
  *"rule add"*)
    if [[ "${FAKE_IP_FAIL_ADD_FAMILY:-}" == "$family" ]]; then echo "RTNETLINK answers: boom" >&2; exit 2; fi
    printf '100:\tfrom all uidrange %s lookup main\n' "$5" >> "$rules" ;;
  *"rule del"*)
    line="$(grep -n -m1 -F "uidrange $5 " "$rules" | cut -d: -f1)"
    sed -i "${line}d" "$rules"
    if [[ -n "${FAKE_IP_BREAK_ON_DEL:-}" ]]; then touch "$FAKE_IP_DIR/broken"; fi ;;
esac
F
printf '#!/usr/bin/env bash\n[[ "$*" == "-u toranon" ]] && echo %s || exit 1\n' "$TOR_UID" > "$work/bin/id"
chmod +x "$work/bin/ip" "$work/bin/id"
export PATH="$work/bin:$PATH"

FOREIGN_RULE=$'100:\tfrom 10.1.0.0/16 lookup 200'
reset() {
  rm -f "$FAKE_IP_DIR/broken" "$FAKE_IP_DIR/calls"
  : > "$FAKE_IP_DIR/calls"
  for family in -4 -6; do
    printf '100:\tfrom all uidrange %s-%s lookup main\n' "$TOR_UID" "$TOR_UID" "$TOR_UID" "$TOR_UID" "$STALE_UID" "$STALE_UID" > "$FAKE_IP_DIR/rules$family"
    echo "$FOREIGN_RULE" >> "$FAKE_IP_DIR/rules$family"
  done
}
route() { unshare -r bash "$REPO/libexec/vekrona-tor-route" "$@" 2>&1; }
deletions() { grep -c -- '^-4 .*rule del' "$FAKE_IP_DIR/calls" || true; }
rules_of() { cat "$FAKE_IP_DIR/rules$1"; }

reset
route down >/dev/null || die "down failed although ip lists and deletes"
for family in -4 -6; do
  [[ "$(rules_of "$family")" == "$FOREIGN_RULE" ]] || die "down must leave only the foreign rule of the family $family, but it left: $(rules_of "$family")"
done
[[ "$(deletions)" == 3 ]] || die "down did not delete each of the three rules of its shape (two duplicates and a stale uid) once"
log "ok: down deletes duplicate and stale rules of its shape until none is left, and no other rule"

reset
route up >/dev/null || die "up failed although ip lists, deletes and adds"
for family in -4 -6; do
  [[ "$(rules_of "$family")" == "$FOREIGN_RULE"$'\n'"100:"$'\t'"from all uidrange $TOR_UID-$TOR_UID lookup main" ]] \
    || die "up must leave the foreign rule and one rule for the tor user in the family $family, but it left: $(rules_of "$family")"
done
log "ok: up leaves one rule for the tor user, replaces a stale one and keeps a foreign one"

reset
touch "$FAKE_IP_DIR/broken"
out="$(route down)" && die "down succeeded although ip cannot list the rules"
[[ "$out" == *"cannot list the ip rules"* ]] || die "down did not say that listing failed: $out"
[[ "$(deletions)" == 0 ]] || die "down deleted rules it could not list"
log "ok: an ip that fails to list is an error"

reset
out="$(FAKE_IP_BREAK_ON_DEL=1 route down)" && die "down succeeded although ip failed to list again after a delete"
[[ "$out" == *"cannot list the ip rules"* ]] || die "down did not say that the second listing failed: $out"
log "ok: an ip that fails to list again after a delete is an error"

[[ -d /proc/sys/net/ipv6 ]] || skip "this kernel has no IPv6, so the rule of the second family cannot fail"
reset
FAKE_IP_FAIL_ADD_FAMILY=-6 route up >/dev/null && die "up succeeded although ip could not add the rule of the IPv6 family"
[[ "$(rules_of -4)" == "$FOREIGN_RULE" ]] || die "an up that failed in the IPv6 family must take back the IPv4 rule it added, but the family -4 has: $(rules_of -4)"
log "ok: an up that fails takes back the rules it added"
