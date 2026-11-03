#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
source "$REPO/tests/lib.sh"
source "$REPO/tests/stages/dnf-fakes.sh"

# The marker is a scratch file: the test passes the same where the real marker exists (the vekrona-dev VM) and where it does not.
VEKRONA_KEEP_SSHD_MARKER="$work/keep-sshd"
unwanted() { vekrona_unwanted_pkgs | tr '\n' ' '; }

rm -f "$VEKRONA_KEEP_SSHD_MARKER"
[[ "$(unwanted)" == *" openssh-server "* ]] || die "without the marker openssh-server is unwanted: $(unwanted)"
touch "$VEKRONA_KEEP_SSHD_MARKER"
[[ "$(unwanted)" != *openssh-server* ]] || die "with the marker openssh-server must stay: $(unwanted)"
[[ "$(unwanted)" == *"abrt "* ]] || die "the marker must not shield the other unwanted packages: $(unwanted)"
log "ok: openssh-server is unwanted unless the keep-sshd marker exists"

rm -f "$VEKRONA_KEEP_SSHD_MARKER"
for pkg in $(vekrona_unwanted_pkgs); do
  [[ " ${VEKRONA_DESKTOP_PKGS[*]} " != *" $pkg "* ]] || die "$pkg is both a desktop package and an unwanted one: stage 30 would install it and then refuse to remove it"
done
log "ok: no unwanted package is a desktop package"

write_fake "$work/bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_SYSTEMCTL_LOG"
F
export FAKE_SYSTEMCTL_LOG="$work/systemctl.log"

packages openssh-server abrt sway
ensure_unwanted_pkgs_absent
! installed openssh-server && ! installed abrt || die "the unwanted packages must be removed"
installed sway || die "a package that is not unwanted must stay"
log "ok: the unwanted packages are removed"
[[ "$(<"$FAKE_SYSTEMCTL_LOG")" == reset-failed ]] || die "a removal must clear the failed units of the packages it removed: $(cat "$FAKE_SYSTEMCTL_LOG")"
log "ok: a removal resets the failed state of units whose package is gone"

packages sway
ensure_unwanted_pkgs_absent
! grep -q remove "$FAKE_DNF_LOG" 2>/dev/null || die "with nothing unwanted installed dnf must not be asked to remove: $(cat "$FAKE_DNF_LOG")"
log "ok: a system without them is left alone"

packages openssh-server sway
if failure="$(FAKE_DNF_PROTECTED=1 ensure_pkg_absent openssh-server 2>&1)"; then
  die "a removal that would take a protected package must fail"
fi
[[ "$failure" == *"would remove protected packages"* ]] || die "the failure must say why: $failure"
installed openssh-server || die "nothing may be removed when the dry run refuses"
! grep -q -- ' -y ' "$FAKE_DNF_LOG" || die "the real removal ran after the dry run refused: $(cat "$FAKE_DNF_LOG")"
log "ok: a removal that would take a protected package dies before removing anything"
