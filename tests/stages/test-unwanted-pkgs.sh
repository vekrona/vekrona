#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# shellcheck source=../lib.sh
source "$REPO/tests/lib.sh"
# shellcheck source=dnf-fakes.sh
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

# bash -c, not a subshell: the test's own assignment above must not stand in for the environment.
env_marker="$(VEKRONA_KEEP_SSHD_MARKER="$work/from-environment" bash -c 'source "$1/tests/lib.sh" && echo "$VEKRONA_KEEP_SSHD_MARKER"' _ "$REPO")"
[[ "$env_marker" == /etc/vekrona/keep-sshd ]] || die "the environment must not move the keep-sshd marker, got $env_marker"
log "ok: the environment cannot move the keep-sshd marker"

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
# A person whose dnf speaks French: only a dry run with LC_ALL=C is read as it is meant.
export LANGUAGE=fr

packages openssh-server abrt sway
ensure_unwanted_pkgs_absent
{ ! installed openssh-server && ! installed abrt; } || die "the unwanted packages must be removed"
installed sway || die "a package that is not unwanted must stay"
log "ok: the unwanted packages are removed"
[[ "$(<"$FAKE_SYSTEMCTL_LOG")" == reset-failed ]] || die "a removal must clear the failed units of the packages it removed: $(cat "$FAKE_SYSTEMCTL_LOG")"
log "ok: a removal resets the failed state of units whose package is gone"

packages sway
ensure_unwanted_pkgs_absent
[[ ! -e "$FAKE_DNF_LOG" ]] || die "with nothing unwanted installed dnf must not be called: $(cat "$FAKE_DNF_LOG")"
log "ok: a system without them is left alone"

# A desktop package (sway) needs the unwanted package: that is a vekrona bug, so it ends the stage before anything is removed.
packages openssh-server abrt sway
needs sway openssh-server
run_as_stage ensure_unwanted_pkgs_absent
[[ $stage_status -ne 0 ]] || die "a removal that would take a desktop package must fail"
[[ "$stage_output" == *"would remove protected packages"* ]] || die "the failure must say why: $stage_output"
all_installed openssh-server abrt || die "nothing may be removed when the dry run refuses"
! grep -q -- ' -y ' "$FAKE_DNF_LOG" || die "the real removal ran after the dry run refused: $(cat "$FAKE_DNF_LOG")"
log "ok: a removal that would take a desktop package dies before removing anything"

# A package the person chose (reason User) needs cups: cups stays and the warning names the package; the rest still goes.
packages cups abrt sway mine
reason mine User
needs mine cups
warnings="$(ensure_unwanted_pkgs_absent 2>&1)" || die "a kept package must not fail the stage: $warnings"
all_installed cups mine || die "cups and the package that needs it must stay"
! installed abrt || die "an unwanted package that nobody needs must still go"
[[ "$warnings" == *"WARN"*"cups stays installed"*"mine"* ]] || die "the warning must name the kept package and its holder: $warnings"
log "ok: an unwanted package that a package you installed needs stays, and is reported with its holder"

# Same again a second time: the warning does not go away by itself.
warnings="$(ensure_unwanted_pkgs_absent 2>&1)"
[[ "$warnings" == *"cups stays installed"* ]] || die "every run must report the kept package: $warnings"
log "ok: the kept package is reported on every run"

# The holder's chain: a chosen package needs a dependency that needs avahi.
packages avahi lib-avahi-thing mine
reason mine User
needs lib-avahi-thing avahi
needs mine lib-avahi-thing
ensure_unwanted_pkgs_absent 2>/dev/null
all_installed avahi lib-avahi-thing mine || die "a chosen package that needs avahi through a dependency must keep it"
log "ok: a package you installed holds an unwanted one through its dependencies too"

# dnf gives "External User" to every package it has no record of, plain dependencies among them: that is not a choice.
packages avahi lib-avahi-thing
reason lib-avahi-thing External\ User
needs lib-avahi-thing avahi
ensure_unwanted_pkgs_absent 2>/dev/null
{ ! installed avahi && ! installed lib-avahi-thing; } || die "a package of the reason External User must not hold an unwanted one"
log "ok: the reason External User is not a choice"

# Only the installer's groups (reason Group) or a dependency need it: nobody chose that, so it goes with its package.
packages cups cups-extra
reason cups-extra Group
needs cups-extra cups
ensure_unwanted_pkgs_absent 2>/dev/null
{ ! installed cups && ! installed cups-extra; } || die "a package that is only a group member or a dependency must not hold an unwanted one"
log "ok: group members and dependencies do not hold an unwanted package"

# Unwanted packages are mostly reason User themselves (the installer named them): they must not hold each other.
packages cups cups-browsed
reason cups User
reason cups-browsed User
needs cups-browsed cups
ensure_unwanted_pkgs_absent 2>/dev/null
{ ! installed cups && ! installed cups-browsed; } || die "unwanted packages must not protect each other"
log "ok: an unwanted package is removed even when it was chosen, and so is what needs it"

# Everything unwanted is held: nothing is removed, no removal is even attempted, and the stage still succeeds.
packages cups avahi abrt mine
reason mine User
needs mine cups avahi abrt
rm -f "$FAKE_SYSTEMCTL_LOG"
ensure_unwanted_pkgs_absent 2>/dev/null
all_installed cups avahi abrt mine || die "everything held must stay"
! grep -q -- ' -y ' "$FAKE_DNF_LOG" || die "dnf was asked to remove although everything is held: $(cat "$FAKE_DNF_LOG")"
[[ ! -e "$FAKE_SYSTEMCTL_LOG" ]] || die "nothing was removed, so no unit has lost its package: $(cat "$FAKE_SYSTEMCTL_LOG")"
log "ok: when every unwanted package is held, nothing is removed"

# A failing package query ends the stage instead of guessing what the person chose.
packages cups
FAKE_DNF_FAIL=1 run_as_stage ensure_unwanted_pkgs_absent
[[ $stage_status -ne 0 ]] || die "a failing dnf must fail the stage"
installed cups || die "nothing may be removed when dnf fails"
log "ok: a failing dnf ends the stage"

# A failing package query (and nothing else failing) ends the stage too: no guessing what the person chose.
packages cups
FAKE_REPOQUERY_FAIL=1 run_as_stage ensure_unwanted_pkgs_absent
[[ $stage_status -ne 0 ]] || die "a failing repoquery must fail the stage"
[[ "$stage_output" == *"dnf repoquery failed"* ]] || die "the failure must say that the query failed: $stage_output"
installed cups || die "nothing may be removed when the query of the chosen packages fails"
log "ok: a failing repoquery ends the stage"

# One package's dry run fails (not a refusal): the stage dies and nothing is removed, not even the packages whose dry run passed.
packages cups avahi mine
reason mine User
needs mine cups
FAKE_DNF_BREAK_ON=avahi run_as_stage ensure_pkg_absent cups avahi
[[ $stage_status -ne 0 ]] || die "a dry run that fails must fail the removal"
[[ "$stage_output" == *"failed unexpectedly"* ]] || die "the failure must say that dnf failed: $stage_output"
all_installed cups avahi mine || die "nothing may be removed when a dry run fails"
! grep -q -- ' -y ' "$FAKE_DNF_LOG" || die "the real removal ran after a dry run failed: $(cat "$FAKE_DNF_LOG")"
log "ok: a failing dry run of one package ends the removal before anything is removed"

# dnf protects itself and the packages of /etc/dnf/protected.d (sudo, systemd, the boot chain) whatever else the call protects: an
# unwanted package one of them needs is a vekrona bug, and ends the stage before anything is removed.
for protected_pkg in dnf5 sudo; do
  packages openssh-server abrt "$protected_pkg"
  needs "$protected_pkg" abrt
  run_as_stage ensure_unwanted_pkgs_absent
  [[ $stage_status -ne 0 ]] || die "a removal that would take $protected_pkg must fail"
  [[ "$stage_output" == *"would remove protected packages"* ]] || die "the failure must say why: $stage_output"
  all_installed openssh-server abrt "$protected_pkg" || die "nothing may be removed when $protected_pkg would go along"
done
log "ok: a removal that would take dnf5 or a package of /etc/dnf/protected.d dies before removing anything"
