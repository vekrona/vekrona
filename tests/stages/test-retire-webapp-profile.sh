#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# A throwaway HOME, set before lib/common.sh derives the Firefox profile root from it.
export HOME="$scratch/home"
mkdir -p "$HOME/.mozilla/firefox" "$scratch/stubs"
# shellcheck source=../lib.sh
source "$ROOT/tests/lib.sh"

# pgrep answers with the status PGREP_STATUS names: 0 a Firefox runs the profile, 1 none does, anything else is its own failure.
write_fake "$scratch/stubs/pgrep" <<'F'
#!/usr/bin/env bash
echo "pgrep $*" >>"$SCRATCH/pgrep-calls"
exit "${PGREP_STATUS:-1}"
F
export SCRATCH="$scratch" PATH="$scratch/stubs:$PATH"

root="$HOME/.mozilla/firefox"
ini="$root/profiles.ini"
# The retired profile sits between two others, and an [Install...] section (Firefox 67 and later) names it as the default of its
# installation, as it does when the user made the webapp profile the default one.
write_profiles() {
  printf '[General]\nStartWithLastProfile=1\n\n[Install4F96D1932A9F858E]\nDefault=%s/vekrona-syncthing\nLocked=1\n\n[Profile0]\nName=default\nIsRelative=1\nPath=a.default\nDefault=1\n\n[Profile1]\nName=vekrona-syncthing\nIsRelative=0\nPath=%s/vekrona-syncthing\n\n[Profile2]\nName=vekrona-youtube\nIsRelative=0\nPath=%s/vekrona-youtube\n' "$root" "$root" "$root" >"$ini"
  mkdir -p "$root/a.default" "$root/vekrona-syncthing/chrome" "$root/vekrona-youtube"
  touch "$root/vekrona-syncthing/prefs.js"
}

write_profiles
retire_webapp_profile syncthing >/dev/null 2>&1
! grep -q 'vekrona-syncthing' "$ini" || die "the retired profile is still in profiles.ini: $(<"$ini")"
[[ ! -e "$root/vekrona-syncthing" ]] || die "the retired profile directory is still there"
log "ok: the profile's entry and directory go"

for kept in Name=default Name=vekrona-youtube StartWithLastProfile=1; do
  grep -qx "$kept" "$ini" || die "the other profiles and the general section must stay, $kept is gone: $(<"$ini")"
done
[[ -d "$root/vekrona-youtube" && -d "$root/a.default" ]] || die "another profile's directory was removed"
log "ok: no other profile or setting is touched"

# Firefox reads [Profile0], [Profile1], ... and stops at the first index that is missing, so a gap hides every later profile.
mapfile -t headers < <(grep -E '^\[Profile[0-9]+\]$' "$ini")
[[ "${headers[*]}" == '[Profile0] [Profile1]' ]] || die "the profile sections must stay numbered from 0 without a gap, got: ${headers[*]}"
awk '/^\[Profile1\]$/ { in_youtube = 1; next } /^\[/ { in_youtube = 0 } in_youtube' "$ini" | grep -qx "Path=$root/vekrona-youtube" \
  || die "the later profile must keep its own settings under its new index: $(<"$ini")"
log "ok: the profiles after the removed one are renumbered and keep their settings"

! grep -q '^\[Install' "$ini" || die "the installation whose default was the retired profile must go: $(<"$ini")"
log "ok: an [Install...] section that pointed at the retired profile goes"

before="$(<"$ini")"
retire_webapp_profile syncthing >/dev/null 2>&1
[[ "$(<"$ini")" == "$before" ]] || die "a second run changed profiles.ini"
log "ok: a second run changes nothing"

rm -f "$ini"
retire_webapp_profile syncthing >/dev/null 2>&1
[[ ! -e "$ini" ]] || die "no profiles.ini is no reason to create one"
log "ok: a Firefox with no profiles.ini is left alone"

write_profiles
if (PGREP_STATUS=0 retire_webapp_profile syncthing) >/dev/null 2>&1; then die "a profile a running Firefox holds must not be removed"; fi
[[ -d "$root/vekrona-syncthing" ]] || die "the profile directory was removed although a Firefox runs it"
grep -q 'vekrona-syncthing' "$ini" || die "the profile left profiles.ini although a Firefox runs it"
grep -qF -- '-P vekrona-syncthing ' "$scratch/pgrep-calls" || die "pgrep must look for the profile by its name: $(<"$scratch/pgrep-calls")"
log "ok: a running Firefox on the profile stops the retirement"

if (PGREP_STATUS=2 retire_webapp_profile syncthing) >/dev/null 2>&1; then die "a failing pgrep cannot tell that no Firefox runs the profile, and must fail the stage"; fi
log "ok: a pgrep that fails fails the stage"
