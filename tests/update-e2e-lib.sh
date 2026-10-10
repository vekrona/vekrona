#!/usr/bin/env bash
# Shared by the update-night-* scenarios (source it after tests/lib.sh). The guest gets a local dnf repo holding
# vekrona-test-update 2.0 while 1.0 is installed, so `dnf5 check-upgrade` finds exactly one update there. Everything
# that waits is a systemctl --wait or an `until` on a guest event, never a sleep.
# The guest must be otherwise up to date: `vekrona-dev run sudo dnf upgrade -y` first.

TEST_PKG=vekrona-test-update
TEST_REPO_DIR=/var/lib/vekrona-test-repo
TEST_REPO_FILE=/etc/yum.repos.d/vekrona-test.repo
NIGHT_UNIT=vekrona-update-night.service
UPDATES_JSON=/var/lib/vekrona/updates.json
OFFLINE_MARKER=/var/lib/vekrona/offline-pending
SYSTEM_DROPIN_DIR=/run/systemd/system

# build_test_rpm VERSION: an empty noarch package, added to the guest repo directory.
build_test_rpm() {
  vekrona-dev run sudo bash -c '
set -euo pipefail
top="$(mktemp -d)"
cat >"$top/pkg.spec" <<SPEC
Name: vekrona-test-update
Version: $2
Release: 1
Summary: Stand-in package for the update pipeline scenarios
License: MIT
BuildArch: noarch
%description
Stand-in package for the update pipeline scenarios.
%install
install -D -m 0644 /dev/null %{buildroot}/usr/share/vekrona-test-update/%{version}
%files
/usr/share/vekrona-test-update/%{version}
SPEC
rpmbuild --define "_topdir $top" -bb "$top/pkg.spec" >/dev/null
install -d "$1"
cp "$top"/RPMS/noarch/*.rpm "$1/"
rm -rf "$top"
' _ "$TEST_REPO_DIR" "$1"
}

# Installs version 1.0 from the guest repo, then publishes 2.0: one dnf update is pending.
publish_test_update() {
  vekrona-dev run sudo dnf install -y rpm-build createrepo_c
  build_test_rpm 1.0
  vekrona-dev run sudo bash -c '
createrepo_c --quiet "$1"
printf "[vekrona-test]\nname=vekrona test\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\n" "$1" >"$2"
' _ "$TEST_REPO_DIR" "$TEST_REPO_FILE"
  vekrona-dev run sudo dnf install -y "$TEST_PKG"
  build_test_rpm 2.0
  vekrona-dev run sudo createrepo_c --quiet --update "$TEST_REPO_DIR"
}

# Fails when the guest has anything pending at all, which a scenario about "nothing pending" cannot tolerate.
require_nothing_pending() {
  vekrona-dev run sudo systemctl start --wait vekrona-update-check.service
  [[ "$(vekrona-dev run sudo jq -r .pending "$UPDATES_JSON")" == false ]] \
    || die "the guest has pending updates: $(vekrona-dev run sudo jq -c '[.groups[] | .items[].name]' "$UPDATES_JSON"). Run 'vekrona-dev run sudo dnf upgrade -y' first"
}

# Runs the check and fails unless the test package is the only pending dnf update.
run_check_expecting_only_the_test_update() {
  vekrona-dev run sudo systemctl start --wait vekrona-update-check.service
  local items
  items="$(vekrona-dev run sudo jq -r '[.groups[] | select(.name == "System packages") | .items[].name] | join(" ")' "$UPDATES_JSON")"
  [[ "$items" == "$TEST_PKG" ]] || die "the guest has other pending updates: '$items'. Run 'vekrona-dev run sudo dnf upgrade -y' first"
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

cleanup_test_update() {
  vekrona-dev run sudo rm -rf "$SYSTEM_DROPIN_DIR/$NIGHT_UNIT.d"
  real_suspend
  vekrona-dev run sudo dnf5 offline clean
  vekrona-dev run sudo rm -f "$OFFLINE_MARKER" /var/lib/vekrona/update-skip
  vekrona-dev run sudo dnf remove -y "$TEST_PKG"
  vekrona-dev run sudo rm -rf "$TEST_REPO_FILE" "$TEST_REPO_DIR"
  vekrona-dev run sudo systemctl start --wait vekrona-update-check.service
}
