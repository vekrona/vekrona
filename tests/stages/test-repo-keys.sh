#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/stages/lib.sh"
FIXTURES="$ROOT/tests/fixtures/rpmfusion"
KEYS="$ROOT/etc/pki/rpm-gpg"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

expect_die() {
  local description="$1" pattern="$2" output
  shift 2
  if output="$("$@" 2>&1)"; then die "$description: expected a failure, the command succeeded"; fi
  [[ "$output" == *"$pattern"* ]] || die "$description: the failure does not mention '$pattern': $output"
  log "ok: $description"
}

for repo in "${!VEKRONA_REPO_KEY_FINGERPRINTS[@]}"; do
  assert_repo_key_file_pinned "$repo" "$KEYS/$(repo_key_name "$repo")"
done
log "ok: every vendored key file holds exactly its pinned fingerprint"

expect_die "a key file with another key than the pinned one is rejected, naming repo, file and both fingerprints" \
  "${VEKRONA_REPO_KEY_FINGERPRINTS[rpmfusion-free-fedora-44]}" \
  assert_repo_key_file_pinned rpmfusion-free-fedora-44 "$KEYS/$(repo_key_name rpmfusion-nonfree-fedora-44)"

cat "$KEYS/$(repo_key_name rpmfusion-free-fedora-44)" "$KEYS/$(repo_key_name rpmfusion-nonfree-fedora-44)" > "$scratch/two-keys"
expect_die "a key file holding the pinned key plus a second primary key is rejected" \
  "must hold exactly one primary key" \
  assert_repo_key_file_pinned rpmfusion-free-fedora-44 "$scratch/two-keys"

printf 'not a key\n' > "$scratch/garbage"
expect_die "a file that is not a gpg key is rejected" "cannot read gpg key file" \
  assert_repo_key_file_pinned rpmfusion-free-fedora-44 "$scratch/garbage"

expect_die "a release without a pinned key fails loudly with instructions" "VEKRONA_REPO_KEY_FINGERPRINTS" \
  assert_repo_key_file_pinned rpmfusion-free-fedora-99 "$KEYS/$(repo_key_name rpmfusion-free-fedora-44)"

for section in free nonfree; do
  assert_rpm_signed_by_pinned_key "rpmfusion-$section-fedora-44" "$FIXTURES/rpmfusion-$section-release-44-3.noarch.rpm"
done
log "ok: both RPM Fusion release RPMs verify against their pinned keys"

expect_die "a release RPM checked against the other repo's pinned key is rejected, naming file and key" \
  "rpmfusion-free-release-44-3.noarch.rpm is not validly signed by the pinned key of repo 'rpmfusion-nonfree-fedora-44' (${VEKRONA_REPO_KEY_FINGERPRINTS[rpmfusion-nonfree-fedora-44]}" \
  assert_rpm_signed_by_pinned_key rpmfusion-nonfree-fedora-44 "$FIXTURES/rpmfusion-free-release-44-3.noarch.rpm"

tampered="$scratch/rpmfusion-free-release-44-3.noarch.rpm"
cp "$FIXTURES/rpmfusion-free-release-44-3.noarch.rpm" "$tampered"
printf '\x00' | dd of="$tampered" bs=1 seek=$(( $(stat -c %s "$tampered") - 1 )) conv=notrunc status=none
expect_die "a release RPM modified after signing is rejected" "is not validly signed by the pinned key" \
  assert_rpm_signed_by_pinned_key rpmfusion-free-fedora-44 "$tampered"
