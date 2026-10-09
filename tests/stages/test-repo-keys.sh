#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib.sh"
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

PROTON_RPM="$ROOT/tests/fixtures/protonvpn/proton-vpn-gnome-desktop-0.11.0-1.fc44.noarch.rpm"
assert_rpm_signed_by_pinned_key protonvpn-fedora-44 "$PROTON_RPM"
log "ok: a Proton VPN RPM verifies against the pinned Proton key"

expect_die "a Proton VPN RPM checked against another repo's pinned key is rejected" \
  "is not validly signed by the pinned key of repo 'rpmfusion-free-fedora-44'" \
  assert_rpm_signed_by_pinned_key rpmfusion-free-fedora-44 "$PROTON_RPM"

proton_repo_file="$ROOT/etc/yum.repos.d/protonvpn-stable.repo"
[[ "$(grep '^gpgkey=' "$proton_repo_file")" == "gpgkey=file://$VEKRONA_REPO_KEY_DIR/$(repo_key_name protonvpn-fedora-)\$releasever" ]] \
  || die "protonvpn-stable.repo does not take its key only from the per-release pinned key file"
for setting in gpgcheck=1 repo_gpgcheck=1; do
  grep -qx "$setting" "$proton_repo_file" || die "protonvpn-stable.repo does not set $setting"
done
[[ "$(protonvpn_key_repo)" == "protonvpn-fedora-$(rpm -E %fedora)" ]] || die "protonvpn_key_repo does not name the running Fedora release"
log "ok: the Proton VPN repo file verifies packages and metadata with the per-release pinned key file"
