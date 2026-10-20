#!/usr/bin/env bash
# Shared by the update-night-* scenarios (source it after tests/lib.sh). The guest gets a local dnf repo holding
# vekrona-test-update 2.0 while 1.0 is installed, so `dnf5 check-upgrade` finds exactly one update there. Everything
# that waits is a systemctl --wait or an `until` on a guest event, never a sleep.
# The guest's own repositories are switched off for the scenario (use_only_the_test_repo), so what Fedora or RPM Fusion
# published meanwhile is no business of the scenario. Flatpak is not dnf: the guest installs no Flatpak app, and a
# scenario would fail on one that appeared.

TEST_PKG=vekrona-test-update
TEST_REPO_ID=vekrona-test
TEST_REPO_DIR=/var/lib/vekrona-test-repo
TEST_REPO_FILE=/etc/yum.repos.d/vekrona-test.repo
# A stand-in for the update a real repository publishes between two runs: it is pending in a repo that the scenario switches off.
DECOY_PKG=vekrona-decoy-update
DECOY_REPO_ID=vekrona-decoy
DECOY_REPO_DIR=/var/lib/vekrona-decoy-repo
DECOY_REPO_FILE=/etc/yum.repos.d/vekrona-decoy.repo
REPOS_OVERRIDE_FILE=/etc/dnf/repos.override.d/zz-vekrona-test.repo
NIGHT_UNIT=vekrona-update-night.service
UPDATES_JSON=/var/lib/vekrona/updates.json
OFFLINE_MARKER=/var/lib/vekrona/offline-pending
SYSTEM_DROPIN_DIR=/run/systemd/system

# build_rpm NAME VERSION DIR: an empty noarch package, added to the repo directory DIR.
build_rpm() {
  vekrona-dev run sudo bash -c '
set -euo pipefail
top="$(mktemp -d)"
cat >"$top/pkg.spec" <<SPEC
Name: $3
Version: $2
Release: 1
Summary: Stand-in package for the update pipeline scenarios
License: MIT
BuildArch: noarch
%description
Stand-in package for the update pipeline scenarios.
%install
install -D -m 0644 /dev/null %{buildroot}/usr/share/%{name}/%{version}
%files
/usr/share/%{name}/%{version}
SPEC
rpmbuild --define "_topdir $top" -bb "$top/pkg.spec" >/dev/null
install -d "$1"
cp "$top"/RPMS/noarch/*.rpm "$1/"
rm -rf "$top"
' _ "$3" "$2" "$1"
}

install_build_tools() { vekrona-dev run sudo dnf install -y rpm-build createrepo_c; }

# publish_update NAME REPO_ID DIR FILE: installs NAME 1.0 from a new local repo and publishes 2.0 there: one dnf update is pending.
publish_update() {
  build_rpm "$1" 1.0 "$3"
  vekrona-dev run sudo bash -c '
createrepo_c --quiet "$1"
printf "[%s]\nname=%s\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\n" "$3" "$3" "$1" >"$2"
' _ "$3" "$4" "$2"
  vekrona-dev run sudo dnf install -y "$1"
  build_rpm "$1" 2.0 "$3"
  vekrona-dev run sudo createrepo_c --quiet --update "$3"
}
publish_test_update() { publish_update "$TEST_PKG" "$TEST_REPO_ID" "$TEST_REPO_DIR" "$TEST_REPO_FILE"; }
publish_decoy_update() { publish_update "$DECOY_PKG" "$DECOY_REPO_ID" "$DECOY_REPO_DIR" "$DECOY_REPO_FILE"; }

# Switches off every dnf repository but the test one, as the guest's own repositories are not the scenario's to control.
use_only_the_test_repo() {
  vekrona-dev run sudo bash -c '
set -euo pipefail
install -d "$(dirname "$1")"
dnf5 repo list --enabled | awk -v keep="$2" "NR > 1 && \$1 != keep { print \$1 }" | while read -r id; do
  printf "[%s]\nenabled=0\n" "$id"
done >"$1"
' _ "$REPOS_OVERRIDE_FILE" "$TEST_REPO_ID"
}

# Fails when the guest has anything pending at all, which a scenario about "nothing pending" cannot tolerate.
require_nothing_pending() {
  vekrona-dev run sudo systemctl start --wait vekrona-update-check.service
  [[ "$(vekrona-dev run sudo jq -r .pending "$UPDATES_JSON")" == false ]] \
    || die "the guest has pending updates besides dnf's: $(vekrona-dev run sudo jq -c '[.groups[] | .items[].name]' "$UPDATES_JSON")"
}

# Runs the check and fails unless the test package is the only pending dnf update.
run_check_expecting_only_the_test_update() {
  vekrona-dev run sudo systemctl start --wait vekrona-update-check.service
  local items
  items="$(vekrona-dev run sudo jq -r '[.groups[] | select(.name == "System packages") | .items[].name] | join(" ")' "$UPDATES_JSON")"
  [[ "$items" == "$TEST_PKG" ]] || die "dnf lists other updates than $TEST_PKG: '$items'"
  [[ "$(vekrona-dev run sudo jq -r '.night_armed' "$UPDATES_JSON")" == true ]] || die "pending updates did not arm the night timer"
  log "ok: the check lists $TEST_PKG and arms the night timer"
}

# night_env KEY=VALUE...: environment for the night service, as a drop-in under /run.
night_env() {
  vekrona-dev run sudo bash -c '
d="$1/$2.d"
shift 2
install -d "$d"
{ printf "[Service]\n"; for kv; do printf "Environment=%s\n" "$kv"; done; } >"$d/zz-test.conf"
systemctl daemon-reload
' _ "$SYSTEM_DROPIN_DIR" "$NIGHT_UNIT" "$@"
}

installed_test_version() { vekrona-dev run rpm -q --qf '%{VERSION}' "$TEST_PKG"; }
night_log() { vekrona-dev run sudo journalctl -u "$NIGHT_UNIT" -o cat --no-pager --since "$1"; }
guest_now() { vekrona-dev run date '+%F %T'; }
# Both ask the guest to run `test`, so an unreachable guest is a failure, never "absent".
marker_exists() { vekrona-dev run sudo test -e "$OFFLINE_MARKER"; }
marker_absent() { vekrona-dev run sudo test ! -e "$OFFLINE_MARKER"; }
offline_transaction_stored() { vekrona-dev run sudo dnf5 offline status 2>&1 | grep -q 'An offline transaction was initiated'; }
# `vekrona-dev until` runs these on the host in a fresh shell.
export OFFLINE_MARKER
export -f marker_exists marker_absent offline_transaction_stored

# dnf refuses to remove a package that is not installed, and a scenario can stop before it installed either one.
remove_installed_test_packages() {
  vekrona-dev run sudo bash -c 'for pkg; do if rpm -q --quiet "$pkg"; then dnf remove -y "$pkg"; fi; done' _ "$TEST_PKG" "$DECOY_PKG"
}
# The marker and the stored transaction send the next boot into an offline update, and the override file switches off every
# repository of the guest: they go first, then the test packages and their repos.
cleanup_test_update() {
  run_cleanups \
    'vekrona-dev run sudo rm -f "$OFFLINE_MARKER" /var/lib/vekrona/update-skip' \
    'vekrona-dev run sudo dnf5 offline clean' \
    'vekrona-dev run sudo rm -rf "$REPOS_OVERRIDE_FILE" "$TEST_REPO_FILE" "$TEST_REPO_DIR" "$DECOY_REPO_FILE" "$DECOY_REPO_DIR"' \
    'vekrona-dev run sudo rm -rf "$SYSTEM_DROPIN_DIR/$NIGHT_UNIT.d"' \
    real_suspend remove_installed_test_packages \
    'vekrona-dev run sudo systemctl start --wait vekrona-update-check.service'
}
