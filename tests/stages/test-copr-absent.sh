#!/usr/bin/env bash
# Removing a COPR removes the gpg key rpm trusts for it as well, whether or not the repo is still enabled.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"

mkdir -p "$work/bin"
# $FAKE_KEYS: one "name-version-release<TAB>summary" line per trusted key. $FAKE_REPOS: one enabled repo id per line.
write_fake "$work/bin/rpm" <<'F'
#!/usr/bin/env bash
case "$*" in
  "-qa gpg-pubkey --qf "*)
    [[ -z "${FAKE_RPM_LIST_FAIL:-}" ]] || exit 1
    cat "$FAKE_KEYS" ;;
  "-q gpg-pubkey --qf "*)
    [[ -z "${FAKE_RPM_LIST_FAIL:-}" ]] || exit 1
    # As rpm does, querying a name that no package has fails.
    [[ -s "$FAKE_KEYS" ]] || { echo "package gpg-pubkey is not installed"; exit 1; }
    cat "$FAKE_KEYS" ;;
  "-q "*) grep -q "^$2	" "$FAKE_KEYS" ;;
  "-e "*)
    [[ -z "${FAKE_RPM_ERASE_FAIL:-}" ]] || exit 1
    echo "$*" >> "$FAKE_RPM_LOG"
    grep -v "^$2	" "$FAKE_KEYS" > "$FAKE_KEYS.new" || true
    mv "$FAKE_KEYS.new" "$FAKE_KEYS" ;;
  *) exit 2 ;;
esac
F
write_fake "$work/bin/dnf" <<'F'
#!/usr/bin/env bash
case "$*" in
  "repolist --enabled") sed 's/$/  a repo/' "$FAKE_REPOS" ;;
  "copr remove -y "*)
    echo "$*" >> "$FAKE_DNF_LOG"
    grep -vx "copr:copr.fedorainfracloud.org:${4/\//:}" "$FAKE_REPOS" > "$FAKE_REPOS.new" || true
    mv "$FAKE_REPOS.new" "$FAKE_REPOS" ;;
  *) exit 2 ;;
esac
F
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
export PATH="$work/bin:$PATH" FAKE_KEYS="$work/keys" FAKE_REPOS="$work/repos" FAKE_DNF_LOG="$work/dnf.log" FAKE_RPM_LOG="$work/rpm.log"

DMS_KEY="gpg-pubkey-162d064397afd540a87168c24bf50d931c31fcae-68e80932"
setup() {
  rm -f "$FAKE_DNF_LOG" "$FAKE_RPM_LOG"
  printf '%s\t%s\n' \
    "$DMS_KEY" "avengemedia_dms (None) <avengemedia#dms@copr.fedorahosted.org> public key" \
    "gpg-pubkey-882b9f1c415ee16ebe149a0dfd1e0ab06c2e4f4a-68e9b263" "avengemedia_danklinux (None) <avengemedia#danklinux@copr.fedorahosted.org> public key" \
    "gpg-pubkey-36f612dcf27f7d1a48a835e4dbfcf71c6d9f90a6-6786af3b" "Fedora (44) <fedora-44-primary@fedoraproject.org> public key" > "$FAKE_KEYS"
  : > "$FAKE_REPOS"
}
key_trusted() { grep -q "^$1	" "$FAKE_KEYS"; }

# The repo went long ago (a COPR removed before vekrona removed keys): only the key is left.
setup
ensure_copr_absent avengemedia/dms
key_trusted "$DMS_KEY" && die "the key of a COPR that is gone must be removed"
[[ "$(wc -l <"$FAKE_KEYS")" -eq 2 ]] || die "only the key of that COPR may go, left: $(cat "$FAKE_KEYS")"
[[ ! -e "$FAKE_DNF_LOG" ]] || die "there is no repo to remove: $(cat "$FAKE_DNF_LOG")"
log "ok: the key of a COPR whose repo is gone is removed, and no other key"

# The repo is still enabled: it goes, and its key with it.
setup
echo "copr:copr.fedorainfracloud.org:avengemedia:dms" > "$FAKE_REPOS"
ensure_copr_absent avengemedia/dms
key_trusted "$DMS_KEY" && die "the key must go with the repo"
[[ -s "$FAKE_REPOS" ]] && die "the repo must go: $(cat "$FAKE_REPOS")"
log "ok: an enabled COPR goes with its key"

# Nothing of it left: nothing is done.
setup
ensure_copr_absent avengemedia/dms
rm -f "$FAKE_RPM_LOG"
ensure_copr_absent avengemedia/dms
[[ ! -e "$FAKE_RPM_LOG" && ! -e "$FAKE_DNF_LOG" ]] || die "a COPR that is gone must be left alone"
log "ok: a COPR that is gone is left alone"

# No gpg key is installed at all: rpm lists none and that is no failure.
setup
: >"$FAKE_KEYS"
ensure_copr_absent avengemedia/dms
[[ ! -e "$FAKE_RPM_LOG" && ! -e "$FAKE_DNF_LOG" ]] || die "with no gpg key installed nothing may be removed"
log "ok: no gpg key installed at all is no failure, and nothing is removed"

# The key that rpm cannot erase, or cannot list, is an error.
setup
FAKE_RPM_ERASE_FAIL=1 run_as_stage ensure_copr_absent avengemedia/dms
[[ $stage_status -ne 0 ]] || die "a key that rpm cannot erase must fail the removal"
key_trusted "$DMS_KEY" || die "the erase failed, so the key is still there"
FAKE_RPM_LIST_FAIL=1 run_as_stage ensure_copr_absent avengemedia/dms
[[ $stage_status -ne 0 ]] || die "an rpm that cannot list the keys must fail the removal"
[[ "$stage_output" == *"cannot list the trusted gpg keys"* ]] || die "the failure must say what failed: $stage_output"
log "ok: an rpm that fails ends the removal"
