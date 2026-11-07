#!/usr/bin/env bash
# A retired vendor repo goes with its repo file, its vendored key file and the key rpm trusts for it; the keys of other repos stay.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"

mkdir -p "$work/bin" "$work/repos.d" "$work/keys.d"
write_fake "$work/bin/rpm" <<'F'
#!/usr/bin/env bash
case "$*" in
  "-qa gpg-pubkey --qf %{VERSION}"*)
    [[ -z "${FAKE_RPM_LIST_FAIL:-}" ]] || exit 1
    awk -F- '{ print $3 }' "$FAKE_KEYS" ;;
  "-q gpg-pubkey --qf %{VERSION} %{NAME}"*)
    [[ -z "${FAKE_RPM_NVR_LIST_FAIL:-}" ]] || exit 1
    awk -F- '{ print $3, $0 }' "$FAKE_KEYS" ;;
  "-q "*) grep -q "^$2	" "$FAKE_KEYS" ;;
  "-e "*)
    grep -v "^$2	" "$FAKE_KEYS" > "$FAKE_KEYS.new" || true
    mv "$FAKE_KEYS.new" "$FAKE_KEYS" ;;
  *) exit 2 ;;
esac
F
write_fake "$work/bin/sudo" <<'F'
#!/usr/bin/env bash
exec "$@"
F
export PATH="$work/bin:$PATH" FAKE_KEYS="$work/keys"
export VEKRONA_YUM_REPOS_DIR="$work/repos.d"
export VEKRONA_REPO_KEY_DIR="$work/keys.d"

PROTON_FPR=6929133BDE1CE1CFA9EDB286D84176F6844830D4
PROTON_NVR="gpg-pubkey-${PROTON_FPR,,}-65f2d4c1"
OTHER_NVR="gpg-pubkey-36f612dcf27f7d1a48a835e4dbfcf71c6d9f90a6-6786af3b"
setup() {
  printf '%s\t%s\n' "$PROTON_NVR" "Proton public key" "$OTHER_NVR" "Fedora (44) public key" > "$FAKE_KEYS"
  echo '[protonvpn-fedora-stable]' > "$work/repos.d/protonvpn-stable.repo"
  echo key > "$work/keys.d/RPM-GPG-KEY-protonvpn-fedora-44"
  echo key > "$work/keys.d/RPM-GPG-KEY-1password"
}

setup
ensure_repo_absent protonvpn-stable.repo protonvpn-fedora-44 "$PROTON_FPR"
[[ ! -e "$work/repos.d/protonvpn-stable.repo" ]] || die "the repo file must go"
[[ ! -e "$work/keys.d/RPM-GPG-KEY-protonvpn-fedora-44" ]] || die "the vendored key file must go"
grep -q "^$PROTON_NVR	" "$FAKE_KEYS" && die "the key rpm trusts must go"
grep -q "^$OTHER_NVR	" "$FAKE_KEYS" || die "another repo's trusted key must stay"
[[ -e "$work/keys.d/RPM-GPG-KEY-1password" ]] || die "another repo's key file must stay"
log "ok: the repo file, its key file and its trusted key go, and nothing else"

ensure_repo_absent protonvpn-stable.repo protonvpn-fedora-44 "$PROTON_FPR"
log "ok: a repo that is gone already is left alone"

# An rpm that cannot list its keys fails the removal, and does not take the key as absent.
setup
FAKE_RPM_LIST_FAIL=1 run_as_stage ensure_repo_absent protonvpn-stable.repo protonvpn-fedora-44 "$PROTON_FPR"
[[ $stage_status -ne 0 ]] || die "an rpm that cannot list the keys must fail the removal"
[[ "$stage_output" == *"cannot list the trusted gpg keys"* ]] || die "the failure must say what failed: $stage_output"
grep -q "^$PROTON_NVR	" "$FAKE_KEYS" || die "the key must stay when rpm cannot list the keys"
log "ok: an rpm that cannot list the keys fails the removal"

# The same when the key is found but rpm cannot list its name for the erase.
setup
FAKE_RPM_NVR_LIST_FAIL=1 run_as_stage ensure_repo_absent protonvpn-stable.repo protonvpn-fedora-44 "$PROTON_FPR"
[[ $stage_status -ne 0 ]] || die "an rpm that cannot list the key's name must fail the removal"
[[ "$stage_output" == *"cannot list the trusted gpg keys"* ]] || die "the failure must say what failed: $stage_output"
grep -q "^$PROTON_NVR	" "$FAKE_KEYS" || die "the key must stay when rpm cannot name it"
log "ok: an rpm that cannot name the key fails the removal"
